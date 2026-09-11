module Rag
  # Salva/chunka/embeda uma LegalNorm — mesma receita de Rag::ProposalIndexer (salva o registro,
  # substitui os chunks existentes, embeda), mas paralela em vez de compartilhada: ProposalIndexer
  # é hardcoded pra HistoricalProposalChunk/historical_proposal_id e é usado pelo pipeline
  # sensível de aprovação do acervo — generalizar essa classe pra servir os dois models trocaria
  # simplicidade por indireção nos dois lados. O que É genérico (Rag::SectionChunker,
  # Rag::Embedder) continua compartilhado; só esta cola de persistência (pequena, ~20 linhas) é
  # duplicada.
  #
  # `record` já vem com os atributos de domínio atribuídos (assign_attributes), ainda não salvo.
  # Embedar fica FORA da transação de escrita — é uma chamada externa (Bedrock).
  class LegalNormIndexer
    def initialize(record, text)
      @record = record
      @text = text
    end

    def call!
      LegalNorm.transaction do
        @record.save!
        @record.chunks.delete_all
        insert_chunks!
      end

      # delete_all acima marca a associação como carregada (vazia) neste objeto; insert_all!
      # (em massa, sem callbacks) não atualiza esse cache sozinho.
      @record.association(:chunks).reset

      embed!
      @record
    end

    private
      def insert_chunks!
        now = Time.current
        rows = Rag::SectionChunker.new(@text).call.map do |chunk|
          {
            legal_norm_id: @record.id, position: chunk.position,
            section_number: chunk.section_number, section_title: chunk.section_title,
            content: chunk.content, token_count: chunk.estimated_tokens,
            created_at: now, updated_at: now
          }
        end

        LegalNormChunk.insert_all!(rows) if rows.any?
      end

      def embed!
        chunks = @record.chunks.pending_embedding.to_a
        return if chunks.empty?

        embedder = Rag::Embedder.new
        chunks.each_slice(Rag::Embedder::MAX_TEXTS_PER_CALL) do |batch|
          vectors = embedder.embed_documents(batch.map(&:content))
          now = Time.current

          batch.each_with_index do |chunk, index|
            chunk.update_columns(embedding: vectors[index], embedding_model: Rag::Embedder::MODEL_ID, embedded_at: now)
          end
        end
      end
  end
end
