class ProcessTrJob < ApplicationJob
  queue_as :default

  # NOTA: não usamos RubyLLM::Schema (structured output) aqui de propósito — no provider
  # Gemini, uma mensagem de resposta estruturada (content_raw) que fica no histórico da
  # conversa quebra qualquer chamada seguinte (erro "Unknown name X at contents[N].parts[0]").
  # Pedimos JSON como texto simples e fazemos o parse manualmente; reavaliar quando migrar
  # para Claude (ver config/initializers/ruby_llm.rb).
  PROMPT = <<~TEXT.freeze
    Você é um assistente que analisa Termos de Referência (TR) de licenciamento ambiental.
    Leia o TR anexado e responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois),
    exatamente neste formato:

    {
      "tipo_licenca": "...",
      "tipo_estudo": "...",
      "orgao_ambiental": "...",
      "municipios": ["..."],
      "diagnosticos": ["..."],
      "condicionantes": ["..."],
      "ressalvas": ["..."]
    }

    Se alguma informação não estiver disponível no TR, use uma lista vazia ou string vazia — nunca invente.
  TEXT

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachment = conversation.attachment_of_kind("tr")
    return conversation.mark_step!("tr", "skipped") unless attachment

    conversation.mark_step!("tr", "running")
    conversation.ask_internally(PROMPT, with: attachment)
    conversation.mark_step!("tr", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessTrJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("tr", "failed")
  ensure
    conversation&.check_processing_complete!
  end
end
