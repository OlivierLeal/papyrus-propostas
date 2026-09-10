module Rag
  # Etapa final compartilhada de indexação de um HistoricalProposal: salva o registro, chunka o
  # texto (Rag::SectionChunker), tageia sensibilidade (Rag::SensitivityTagger) e embeda
  # (Rag::Embedder). Extraído de IndexApprovedProposalJob pra ser reaproveitado também pela
  # aprovação de HistoricalProposal#approve! (ver "aprender com a versão final revisada",
  # CLAUDE.md seção 11.1) — os dois caminhos convergem no mesmo texto->chunks->embedding, só o
  # GATILHO (aprovação de proposta × aprovação de card no chat) e a origem/review_status mudam.
  #
  # `record` já vem com os atributos de domínio atribuídos (assign_attributes), ainda não salvo
  # ou já persistido — #call! salva, substitui os chunks existentes (idempotente num re-envio do
  # mesmo arquivo) e embeda. Embedar fica FORA da transação de escrita — é uma chamada externa, e
  # não faz sentido segurar a transação do banco esperando a rede.
  class ProposalIndexer
    def initialize(record, text)
      @record = record
      @text = text
    end

    def call!
      HistoricalProposal.transaction do
        @record.save!
        @record.chunks.delete_all
        insert_chunks!
      end

      # `delete_all` acima marca a associação como carregada (vazia) NESTE objeto; os chunks
      # inseridos por #insert_chunks! (insert_all!, em massa, sem passar pelos callbacks do
      # ActiveRecord) não atualizam esse cache sozinhos. Sem isso, `@record.chunks` devolveria
      # [] pra qualquer chamador que reuse o mesmo objeto logo depois de #call! retornar.
      @record.association(:chunks).reset

      embed!
      @record
    end

    private
      def insert_chunks!
        now = Time.current
        rows = Rag::SectionChunker.new(@text).call.map do |chunk|
          tags = Rag::SensitivityTagger.new(chunk.content).call

          {
            historical_proposal_id: @record.id, position: chunk.position,
            section_number: chunk.section_number, section_title: chunk.section_title,
            content: chunk.content, token_count: chunk.estimated_tokens,
            sensitive: tags.sensitive, contains_pricing: tags.contains_pricing,
            sensitivity_reasons: tags.reasons, created_at: now, updated_at: now
          }
        end

        HistoricalProposalChunk.insert_all!(rows) if rows.any?
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
