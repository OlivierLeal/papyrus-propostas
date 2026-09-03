class ProcessTrJob < ApplicationJob
  queue_as :default

  # O TR (Termo de Referência, documento do órgão ambiental/instituição) é OPCIONAL — nem todo
  # cliente tem ou envia um; quando existe, ele guia COMO o ET deve ser executado, e não é a base
  # do escopo em si (ver ProcessEtJob e a nota de terminologia em CLAUDE.md seção 2).
  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachments = conversation.attachments_of_kind("tr")
    return conversation.mark_step!("tr", "skipped") if attachments.empty?

    conversation.mark_step!("tr", "running")

    prepared = AttachmentPreparer.new(attachments).call
    Rails.logger.info("[ProcessTrJob] anexos convertidos para texto: #{prepared.converted.join(', ')}") if prepared.converted?

    conversation.ask_internally(
      [ prompt, prepared.inline_text ].compact_blank.join("\n\n"),
      with: prepared.attachments,
      hide_response: true
    )
    record_findings!(conversation, attachments)
    conversation.assign_study_type_from_findings!
    conversation.mark_step!("tr", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessTrJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("tr", "failed")
  ensure
    conversation&.check_processing_complete!
  end

  private
    # Ver nota em ProcessEtJob sobre não usar RubyLLM::Schema (structured output) com Gemini.
    def prompt
      menu = StudyType.order(:name).map { |t| "- código: #{t.code} | #{t.name}" }.join("\n")
      fields = ProjectFinding::FIELDS.map { |key, config| "- #{key}: #{config[:label]}" }.join("\n")

      <<~TEXT
        Você é um assistente que analisa TRs (Termo de Referência) de licenciamento ambiental — o
        documento que vem do ÓRGÃO AMBIENTAL/instituição, com as exigências técnicas de COMO o
        estudo pedido pelo cliente (no ET) deve ser executado: metodologia, diagnósticos exigidos,
        condicionantes. O TR não substitui o ET nem descreve o que o cliente quer — ele guia como
        atender essa exigência regulatória. Pode haver mais de um arquivo anexado — leia todos
        juntos, como um só documento.

        Devolva o que você encontrou como uma LISTA DE ACHADOS. Cada achado é uma informação com a
        prova de onde ela saiu: o campo, o valor, se aquilo está escrito no documento ou foi você
        que deduziu, o trecho literal e onde ele está.

        Campos disponíveis (use exatamente estas chaves; o que não couber em nenhuma delas use
        "outro", com o nome do assunto no campo "valor"):
        #{fields}

        Para "tipo_estudo", o valor deve ser o CÓDIGO EXATO de um dos tipos cadastrados abaixo,
        nunca um tipo inventado. Se o TR não deixar claro qual se aplica, não gere esse achado:
        #{menu}

        Em "empreendimento", descreva O QUE está sendo licenciado em uma ou duas frases: tipo de
        empreendimento, tecnologia e porte. É por esse campo que o sistema procura projetos
        semelhantes no acervo, então descreva o empreendimento — nunca o cliente, o contato ou o
        prazo.

        Campos de lista (diagnosticos, condicionantes, ressalvas, produtos, municipios) devem virar
        UM ACHADO POR ITEM, cada um com o seu próprio trecho — não junte tudo num valor só.

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
              "campo": "condicionantes",
              "valor": "Apresentar plano de monitoramento de fauna trimestral",
              "natureza": "fato",
              "trecho": "...deverá apresentar plano de monitoramento de fauna com periodicidade trimestral...",
              "local": "item 4.2"
            }
          ]
        }

        Se o TR não trouxer alguma informação, simplesmente não gere achado para ela — nunca invente.
      TEXT
    end

    # Grava os achados com o documento de origem. Vários anexos entram como um documento só para a
    # IA (é assim que o TR é lido), então o blob registrado é o do arquivo principal.
    def record_findings!(conversation, attachments)
      reply = conversation.messages.where(role: "assistant").order(:created_at).last
      return unless reply

      ProjectFindings::Recorder.new(
        conversation, source_kind: "tr", source_blob: attachments.first&.blob
      ).call(AiJsonResponse.parse(reply.content))
    end
end
