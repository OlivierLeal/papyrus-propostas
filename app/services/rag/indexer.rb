module Rag
  # Etapa 5: grava no banco o que a Rag::Ingestion produziu e gera os embeddings.
  #
  # É a única etapa que custa dinheiro, então é idempotente por construção: um documento só é
  # reprocessado se o conteúdo mudou (SHA256) ou se a regra de corte mudou (PIPELINE_VERSION).
  # Rodar de novo sobre o mesmo acervo não re-embeda — e não re-cobra — nada.
  class Indexer
    # Suba isto sempre que mudar extração ou chunking de forma que altere os trechos gerados.
    # É o que autoriza o pipeline a descartar e refazer o que já estava indexado.
    PIPELINE_VERSION = "1".freeze

    Result = Data.define(:indexed, :skipped, :chunks, :embedded, :failed) do
      def to_s
        "#{indexed} documentos indexados, #{skipped} inalterados, " \
        "#{chunks} chunks, #{embedded} embeddings gerados, #{failed} falhas"
      end
    end

    def initialize(embed: true, embedder: nil)
      @embed = embed
      @embedder = embedder || Embedder.new
      @stats = Hash.new(0)
    end

    def call(jobs)
      jobs.each { |job| index_job(job) }
      embed_pending! if @embed

      Result.new(indexed: @stats[:indexed], skipped: @stats[:skipped], chunks: @stats[:chunks],
                 embedded: @stats[:embedded], failed: @stats[:failed])
    end

    private

    def index_job(job)
      job.documents.each { |document| index_document(job, document) }
    end

    def index_document(job, document)
      existing = HistoricalProposal.find_by(source_sha256: document.item.sha256)

      if existing && existing.chunker_version == PIPELINE_VERSION
        # Mesmo arquivo, mesma regra de corte: os chunks e vetores que já estão lá continuam
        # válidos. Só os metadados de job/papel são atualizados, que são baratos.
        existing.update!(document_attributes(job, document))
        @stats[:skipped] += 1
        return
      end

      HistoricalProposal.transaction do
        record = existing || HistoricalProposal.new(source_sha256: document.item.sha256)
        record.assign_attributes(document_attributes(job, document).merge(chunker_version: PIPELINE_VERSION))
        record.save!

        record.chunks.delete_all
        insert_chunks(record, document.chunks)
      end

      @stats[:indexed] += 1
      @stats[:chunks] += document.chunks.size
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.error("[Rag::Indexer] #{document.item.relative_path}: #{e.class} #{e.message}")
      @stats[:failed] += 1
    end

    def document_attributes(job, document)
      item = document.item

      {
        job_name: job.name, job_number: job.numero, client_name: job.client_name, subject: job.subject,
        source_path: item.path, relative_path: item.relative_path, filename: item.filename,
        role: document.role, role_source: document.role_source.to_s,
        status: document.status.to_s, page_count: document.page_count,
        revision: item.revision, year: item.year, superseded: item.superseded,
        spreadsheet_path: item.spreadsheet_path, error_message: document.error
      }
    end

    def insert_chunks(record, chunks)
      return if chunks.empty?

      now = Time.current
      rows = chunks.map do |chunk|
        {
          historical_proposal_id: record.id, position: chunk.position,
          section_number: chunk.section_number, section_title: chunk.section_title,
          content: chunk.content, token_count: chunk.estimated_tokens,
          sensitive: chunk.sensitive, contains_pricing: chunk.contains_pricing,
          sensitivity_reasons: chunk.sensitivity_reasons,
          created_at: now, updated_at: now
        }
      end

      HistoricalProposalChunk.insert_all!(rows)
    end

    # Os embeddings são gerados depois de tudo gravado, em lotes que atravessam documentos:
    # o limite do Cohere é por chamada (96 textos), não por documento, então agrupar assim
    # reduz bastante o número de chamadas em um acervo com muitos arquivos pequenos.
    def embed_pending!
      HistoricalProposalChunk.pending_embedding.indexable
        .in_batches(of: Embedder::MAX_TEXTS_PER_CALL) { |batch| embed_batch(batch.to_a) }
    end

    def embed_batch(chunks)
      vectors = @embedder.embed_documents(chunks.map(&:content))
      now = Time.current

      chunks.each_with_index do |chunk, index|
        chunk.update_columns(embedding: vectors[index], embedding_model: Embedder::MODEL_ID, embedded_at: now)
      end

      @stats[:embedded] += chunks.size
    rescue StandardError => e
      # Uma falha de lote não pode perder o que já foi indexado: os chunks ficam sem
      # embedded_at e a próxima execução tenta de novo só eles.
      Rails.logger.error("[Rag::Indexer] falha ao embedar lote de #{chunks.size}: #{e.class} #{e.message}")
      @stats[:failed] += chunks.size
    end
  end
end
