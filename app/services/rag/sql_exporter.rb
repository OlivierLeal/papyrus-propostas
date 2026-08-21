module Rag
  # Exporta o acervo já indexado como SQL, para carregar em outro banco (produção).
  #
  # A ingestão precisa de OCR, LibreOffice, credenciais do Bedrock e horas de processamento —
  # nada disso faz sentido repetir no servidor, ainda mais pagando embedding de novo pelo mesmo
  # conteúdo. Indexa-se uma vez aqui e leva-se o resultado pronto.
  #
  # O SQL é idempotente e não carrega ids: cada documento é casado pelo SHA256 do arquivo, que
  # é chave única. Rodar o mesmo arquivo duas vezes atualiza em vez de duplicar, e um acervo
  # exportado em partes pode ser carregado em qualquer ordem.
  class SqlExporter
    # Casas decimais do vetor. O modelo devolve muito mais, mas a partir daqui a diferença não
    # muda vizinhança nenhuma na busca — e cada casa a menos corta ~8% do arquivo, que é quase
    # todo número (1024 dimensões por trecho).
    VECTOR_PRECISION = 6

    # Trechos por INSERT. Linhas demais numa só instrução estouram memória no psql do outro
    # lado; poucas demais enchem o arquivo de boilerplate.
    CHUNK_BATCH = 50

    PROPOSAL_COLUMNS = %w[
      job_name job_number client_name subject source_path relative_path filename
      source_sha256 chunker_version role role_source status page_count revision year
      superseded spreadsheet_path pricing_data error_message created_at updated_at
    ].freeze

    CHUNK_COLUMNS = %w[
      position section_number section_title content token_count
      sensitive contains_pricing sensitivity_reasons embedding embedding_model embedded_at
      created_at updated_at
    ].freeze

    def initialize(scope: nil)
      @scope = scope || HistoricalProposal.all
    end

    # Escreve direto no IO em vez de montar a string inteira: o acervo completo passa
    # facilmente de 100 MB de SQL, quase tudo vetor.
    def call(io)
      write_header(io)

      @scope.includes(:chunks).find_each do |proposal|
        write_proposal(io, proposal)
      end

      io << "\nCOMMIT;\n"
    end

    private

    def connection = HistoricalProposal.connection

    def write_header(io)
      io << <<~SQL
        -- Acervo histórico da Papyrus para o RAG (CLAUDE.md seção 11.1).
        -- Gerado em #{Time.current.iso8601} por script/rag/export.rb
        -- #{@scope.count} documentos, #{HistoricalProposalChunk.where(historical_proposal: @scope).count} trechos.
        --
        -- Carregar com:  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f acervo.sql
        -- Requer a extensão pgvector e as migrations já aplicadas no destino.

        BEGIN;

      SQL
    end

    def write_proposal(io, proposal)
      sha = connection.quote(proposal.source_sha256)

      io << "\n-- #{proposal.job_number} · #{proposal.client_name} · #{proposal.filename} (#{proposal.chunks.size} trechos)\n"
      io << insert_proposal(proposal)

      # Substitui os trechos em vez de somar: reexportar um documento reprocessado não pode
      # deixar os trechos da versão antiga para trás.
      io << "DELETE FROM historical_proposal_chunks\n" \
            " WHERE historical_proposal_id = (SELECT id FROM historical_proposals WHERE source_sha256 = #{sha});\n"

      proposal.chunks.order(:position).each_slice(CHUNK_BATCH) do |batch|
        io << insert_chunks(batch, sha)
      end
    end

    def insert_proposal(proposal)
      values = PROPOSAL_COLUMNS.map { |column| quote(proposal[column]) }.join(", ")
      # Tudo menos a chave natural é atualizado: o conteúdo do arquivo não mudou (o SHA é o
      # mesmo), mas metadados de job e classificação de papel podem ter melhorado.
      updates = (PROPOSAL_COLUMNS - %w[source_sha256 created_at])
        .map { |column| "#{column} = EXCLUDED.#{column}" }.join(", ")

      "INSERT INTO historical_proposals (#{PROPOSAL_COLUMNS.join(', ')})\n" \
      "VALUES (#{values})\n" \
      "ON CONFLICT (source_sha256) DO UPDATE SET #{updates};\n"
    end

    def insert_chunks(chunks, sha)
      rows = chunks.map do |chunk|
        values = CHUNK_COLUMNS.map { |column| quote_chunk(chunk, column) }.join(", ")
        "  ((SELECT id FROM historical_proposals WHERE source_sha256 = #{sha}), #{values})"
      end

      "INSERT INTO historical_proposal_chunks (historical_proposal_id, #{CHUNK_COLUMNS.join(', ')})\nVALUES\n" \
      "#{rows.join(",\n")};\n"
    end

    def quote_chunk(chunk, column)
      return quote_vector(chunk.embedding) if column == "embedding"
      return quote_array(chunk.sensitivity_reasons) if column == "sensitivity_reasons"

      quote(chunk[column])
    end

    def quote(value)
      case value
      when nil then "NULL"
      when true, false then value.to_s
      when Time, ActiveSupport::TimeWithZone, Date then connection.quote(value)
      when Hash, Array then connection.quote(value.to_json)
      else connection.quote(value)
      end
    end

    def quote_array(values)
      return "'{}'" if values.blank?

      "ARRAY[#{Array(values).map { |v| connection.quote(v) }.join(', ')}]::varchar[]"
    end

    # pgvector aceita o literal no formato '[0.1,0.2,...]'; o cast explícito evita depender de
    # inferência de tipo, que falha dentro de INSERT com múltiplas linhas.
    def quote_vector(embedding)
      return "NULL" if embedding.blank?

      numbers = embedding.map { |value| value.to_f.round(VECTOR_PRECISION) }
      "'[#{numbers.join(',')}]'::vector"
    end
  end
end
