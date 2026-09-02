class GeneralMessage < ApplicationRecord
  acts_as_message chat: :general_chat, tool_calls: :general_tool_calls
  has_many_attached :attachments

  # Mesmo motivo de Message#hide_tool_result! — o JSON cru de uma tool call (search_historical_
  # archive, search_legal_norms) nasce com role "tool" e não deve virar bolha própria no chat.
  before_save :hide_tool_result!

  private
    def hide_tool_result!
      self.internal = true if role == "tool"
    end

    # Mesmo motivo de Message#attachment_sources: cada arquivo só precisa ser lido bruto UMA VEZ
    # pela IA — a mensagem que dispara a leitura já ganha sua cópia, e o que ela conclui fica salvo
    # como texto na resposta. Sem esse filtro, um documento anexado continuaria sendo reenviado em
    # TODA chamada seguinte (mesmo turnos que não têm nada a ver com ele), até estourar o limite de
    # 5 documentos por request que a Anthropic aplica (RubyLLM::BadRequestError). Não existe aqui o
    # caso do KMZ nem do snapshot de estado (exclusivos de Message/Conversation, ligados a
    # proposta) — só a regra "sempre a mensagem de usuário mais recente".
    def attachment_sources
      super.reject { |_attachment, _attachable| stale_for_llm? }
    end

    def stale_for_llm?
      latest_id = general_chat.messages.where(role: "user")
        .reorder(created_at: :desc, id: :desc).limit(1).pick(:id)
      id != latest_id
    end
end
