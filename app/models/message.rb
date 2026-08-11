class Message < ApplicationRecord
  acts_as_message chat: :conversation
  has_many_attached :attachments

  private
    # O KMZ é geoespacial (RGeo/PostGIS), não é lido pela IA (ver CLAUDE.md seção 3). Sem esse
    # filtro, o ruby_llm reenvia TODOS os anexos do histórico em toda chamada — e como o Gemini
    # não suporta o mime type do KMZ, isso quebra qualquer .ask()/.complete() posterior, mesmo
    # em conversas onde a instrução atual não tem nada a ver com o KMZ.
    def attachment_sources
      super.reject { |attachment, _attachable| attachment.blob.metadata["kind"] == "kmz" }
    end
end
