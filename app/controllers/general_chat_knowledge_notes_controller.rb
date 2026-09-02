# Aprovação das notas propostas pela IA no chat geral (ver KnowledgeNote) — mesmo mecanismo de
# KnowledgeNotesController, só que a nota nasce de um GeneralChat em vez de uma Conversation.
class GeneralChatKnowledgeNotesController < ApplicationController
  before_action :set_note

  def approve
    @note.approve!(Current.session.user) if @note.pending?
    respond_with_note
  rescue StandardError => e
    Rails.logger.error("Falha ao aprovar knowledge_note #{@note.id}: #{e.class} #{e.message}")
    redirect_to @general_chat, alert: "Não consegui guardar essa informação agora. Tente novamente."
  end

  def reject
    @note.reject!(Current.session.user) if @note.pending?
    respond_with_note
  end

  private
    def set_note
      @general_chat = Current.session.user.general_chats.find(params[:general_chat_id])
      @note = @general_chat.knowledge_notes.find(params[:id])
    end

    def respond_with_note
      respond_to do |format|
        format.turbo_stream { render "knowledge_notes/#{action_name}" }
        format.html { redirect_to @general_chat }
      end
    end
end
