class ProcessTrJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachments = conversation.attachments_of_kind("tr")
    return conversation.mark_step!("tr", "skipped") if attachments.empty?

    conversation.mark_step!("tr", "running")

    # TR em Word/PDF com fotos passa dos 4,5 MB que o provider aceita por documento; o
    # AttachmentPreparer converte esses em texto para a análise não falhar por peso de imagem.
    prepared = AttachmentPreparer.new(attachments).call
    Rails.logger.info("[ProcessTrJob] anexos convertidos para texto: #{prepared.converted.join(', ')}") if prepared.converted?

    conversation.ask_internally(
      [ prompt, prepared.inline_text ].compact_blank.join("\n\n"),
      with: prepared.attachments,
      hide_response: true
    )
    assign_study_type!(conversation)
    conversation.mark_step!("tr", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessTrJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("tr", "failed")
  ensure
    conversation&.check_processing_complete!
  end

  private
    # NOTA: não usamos RubyLLM::Schema (structured output) aqui de propósito — no provider
    # Gemini, uma mensagem de resposta estruturada (content_raw) que fica no histórico da
    # conversa quebra qualquer chamada seguinte (erro "Unknown name X at contents[N].parts[0]").
    # Pedimos JSON como texto simples e fazemos o parse manualmente; reavaliar quando migrar
    # para Claude (ver config/initializers/ruby_llm.rb).
    #
    # O menu de tipos de estudo é montado na hora (não fica em constante) pra sempre refletir os
    # StudyType cadastrados — mesma regra já usada na sugestão de equipe
    # (Proposal#build_with_ai_suggested_team!): a IA só pode responder com um código do menu,
    # nunca inventar um tipo de estudo novo.
    def prompt
      menu = StudyType.order(:name).map { |t| "- código: #{t.code} | #{t.name}" }.join("\n")

      <<~TEXT
        Você é um assistente que analisa Termos de Referência (TR) de licenciamento ambiental. Pode
        haver mais de um arquivo anexado (ex.: o TR principal e anexos/exhibits) — leia todos juntos,
        como um só documento, e responda APENAS com um JSON válido (sem markdown, sem texto antes ou
        depois), exatamente neste formato:

        {
          "tipo_licenca": "...",
          "tipo_estudo_codigo": "...",
          "orgao_ambiental": "...",
          "municipios": ["..."],
          "diagnosticos": ["..."],
          "condicionantes": ["..."],
          "ressalvas": ["..."]
        }

        Tipos de estudo cadastrados no sistema (responda "tipo_estudo_codigo" com o código exato de
        UM destes, nunca invente um tipo novo; se o TR não deixar claro qual se aplica, use ""):
        #{menu}

        Se alguma outra informação não estiver disponível no TR, use uma lista vazia ou string vazia — nunca invente.
      TEXT
    end

    def assign_study_type!(conversation)
      return if conversation.study_type_id.present?

      reply = conversation.messages.where(role: "assistant").order(:created_at).last
      return unless reply

      parsed = AiJsonResponse.parse(reply.content)
      return unless parsed

      study_type = StudyType.find_by(code: parsed["tipo_estudo_codigo"])
      conversation.update!(study_type: study_type) if study_type
    end
end
