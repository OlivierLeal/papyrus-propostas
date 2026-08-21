class ProcessCompDocsJob < ApplicationJob
  queue_as :default

  # Ver nota em ProcessTrJob sobre não usar RubyLLM::Schema (structured output) com Gemini.
  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachments = conversation.attachments_of_kind("complementary")
    return conversation.mark_step!("comp_docs", "skipped") if attachments.empty?

    conversation.mark_step!("comp_docs", "running")

    attachments.each do |attachment|
      # Mesmo teto de tamanho do TR — um complementar pesado (planta, relatório escaneado)
      # não pode derrubar a análise dos demais.
      prepared = AttachmentPreparer.new(attachment).call
      conversation.ask_internally(
        [ prompt_for(attachment), prepared.inline_text ].compact_blank.join("\n\n"),
        with: prepared.attachments,
        hide_response: true
      )
    end

    conversation.mark_step!("comp_docs", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessCompDocsJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("comp_docs", "failed")
  ensure
    conversation&.check_processing_complete!
  end

  private
    def prompt_for(attachment)
      <<~TEXT
        Analise o documento complementar anexado (#{attachment.filename}) e responda APENAS com um
        JSON válido (sem markdown, sem texto antes ou depois), exatamente neste formato:

        {
          "tipo_documento": "...",
          "resumo": "...",
          "informacoes_relevantes": ["..."]
        }
      TEXT
    end
end
