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
      record_findings!(conversation, attachment)
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
      fields = ProjectFinding::FIELDS.map { |key, config| "- #{key}: #{config[:label]}" }.join("\n")

      <<~TEXT
        Analise o documento complementar anexado (#{attachment.filename}) e devolva o que ele traz
        sobre ESTE projeto como uma LISTA DE ACHADOS: cada informação com o campo, o valor, se
        aquilo está escrito no documento ou foi você que deduziu, o trecho literal e onde ele está.

        Este documento NÃO é o Termo de Referência — é material de apoio (projeto básico, licença
        anterior, ata, ofício, proposta antiga, norma). Extraia o que ele afirma, mesmo que
        contradiga o que o TR diz: quem compara as fontes é o sistema, e a divergência é
        justamente o que interessa descobrir. Nunca ajuste um valor para "bater" com o TR.

        Campos disponíveis (use exatamente estas chaves; o que não couber em nenhuma delas use
        "outro", com o nome do assunto no campo "valor"):
        #{fields}

        O primeiro achado deve ser sempre o campo "outro" com o TIPO deste documento (ex.:
        "tipo de documento: projeto básico").

        Campos de lista (diagnosticos, condicionantes, ressalvas, produtos, municipios) devem virar
        UM ACHADO POR ITEM, cada um com o seu próprio trecho.

        "natureza" é uma de:
        - "fato": está escrito no documento. Só use quando o trecho comprovar o valor.
        - "inferencia": você concluiu juntando informações, mas o documento não diz isso com todas
          as letras.
        - "sugestao": recomendação sua, não uma informação do documento.

        "trecho" deve ser texto COPIADO do documento, palavra por palavra, curto (até 300
        caracteres). Nunca parafraseie nem invente um trecho: ele é mostrado ao consultor para ele
        conferir. Achado de natureza "inferencia" ou "sugestao" pode vir sem trecho.

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "achados": [
            {
              "campo": "area_ha",
              "valor": "620,4",
              "natureza": "fato",
              "trecho": "A área total do empreendimento é de 620,4 ha...",
              "local": "item 2, p. 8"
            }
          ]
        }
      TEXT
    end

    def record_findings!(conversation, attachment)
      reply = conversation.messages.where(role: "assistant").order(:created_at).last
      return unless reply

      ProjectFindings::Recorder.new(
        conversation, source_kind: "complementar", source_blob: attachment.blob
      ).call(AiJsonResponse.parse(reply.content))
    end
end
