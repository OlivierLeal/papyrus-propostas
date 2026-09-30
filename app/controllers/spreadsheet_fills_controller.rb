# Botão "Preencher" de uma planilha do cliente (aba Arquivos da proposta e Tela de Precificação).
# Mesmo caminho do chat (FillClientSpreadsheetTool): só enfileira FillClientSpreadsheetJob, e o
# resultado chega como card no chat. Pedido explícito vence a classificação anterior de "referência".
class SpreadsheetFillsController < ApplicationController
  def create
    conversation = Conversation.find(params[:conversation_id])
    return redirect_back_or_to(conversation, alert: "Avance para a precificação antes de preencher planilhas.") unless conversation.proposal&.project_pricing

    attachment = SpreadsheetFill.client_spreadsheets(conversation).find { |a| a.id == params[:attachment_id].to_i }
    return redirect_back_or_to(conversation, alert: "Planilha não encontrada nesta proposta.") unless attachment

    previous = conversation.spreadsheet_fills.where(source_blob_id: attachment.blob_id).last
    unless previous&.processing?
      fill = conversation.spreadsheet_fills.create!(source_blob: attachment.blob, forced: previous&.not_applicable? || false)
      FillClientSpreadsheetJob.perform_later(fill.id)
    end
    redirect_back_or_to conversation, notice: "Preenchendo #{attachment.filename} — o resultado aparece no chat em instantes."
  end
end
