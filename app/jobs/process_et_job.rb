class ProcessEtJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachments = conversation.attachments_of_kind("et")
    return conversation.mark_step!("et", "skipped") if attachments.empty?

    conversation.mark_step!("et", "running")

    # ET em Word/PDF com fotos passa dos 4,5 MB que o provider aceita por documento; o
    # AttachmentPreparer converte esses em texto para a análise não falhar por peso de imagem.
    prepared = AttachmentPreparer.new(attachments).call
    Rails.logger.info("[ProcessEtJob] anexos convertidos para texto: #{prepared.converted.join(', ')}") if prepared.converted?

    conversation.ask_internally(
      [ prompt, prepared.inline_text ].compact_blank.join("\n\n"),
      with: prepared.attachments,
      hide_response: true
    )
    record_findings!(conversation, attachments)
    assign_study_type!(conversation)
    conversation.mark_step!("et", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessEtJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("et", "failed")
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
      fields = ProjectFinding::FIELDS.map { |key, config| "- #{key}: #{config[:label]}" }.join("\n")

      <<~TEXT
        Você é um assistente que analisa ETs (Pedido Técnico do Estudo) de licenciamento ambiental
        — o documento em que o CLIENTE explica o que está pedindo à Papyrus, base do escopo desta
        proposta. Pode haver mais de um arquivo anexado (ex.: o ET principal e anexos/exhibits) —
        leia todos juntos, como um só documento.

        Devolva o que você encontrou como uma LISTA DE ACHADOS. Cada achado é uma informação com a
        prova de onde ela saiu: o campo, o valor, se aquilo está escrito no documento ou foi você
        que deduziu, o trecho literal e onde ele está.

        Campos disponíveis (use exatamente estas chaves; o que não couber em nenhuma delas use
        "outro", com o nome do assunto no campo "valor"):
        #{fields}

        Para "tipo_estudo", o valor deve ser o CÓDIGO EXATO de um dos tipos cadastrados abaixo,
        nunca um tipo inventado. Se o ET não deixar claro qual se aplica, não gere esse achado:
        #{menu}

        Em "empreendimento", descreva O QUE está sendo licenciado em uma ou duas frases: tipo de
        empreendimento, tecnologia e porte (ex.: "usina fotovoltaica de 200 MW", "sistema de
        armazenamento de energia em baterias associado a complexo eólico", "linha de transmissão
        de 230 kV com 40 km"). É por esse campo que o sistema procura projetos semelhantes no
        acervo, então descreva o empreendimento — nunca o cliente, o contato ou o prazo.

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
              "campo": "tipo_licenca",
              "valor": "Licença Prévia",
              "natureza": "fato",
              "trecho": "...para obtenção da Licença Prévia junto ao órgão estadual...",
              "local": "item 3.1"
            }
          ]
        }

        Se o ET não trouxer alguma informação, simplesmente não gere achado para ela — nunca invente.
      TEXT
    end

    # Grava os achados com o documento de origem. Vários anexos entram como um documento só para a
    # IA (é assim que o ET é lido), então o blob registrado é o do arquivo principal — o trecho e o
    # "local" continuam apontando onde conferir dentro dele.
    def record_findings!(conversation, attachments)
      reply = conversation.messages.where(role: "assistant").order(:created_at).last
      return unless reply

      ProjectFindings::Recorder.new(
        conversation, source_kind: "et", source_blob: attachments.first&.blob
      ).call(AiJsonResponse.parse(reply.content))
    end

    def assign_study_type!(conversation)
      return if conversation.study_type_id.present?

      codes = conversation.project_findings.active.where(field: "tipo_estudo").pluck(:value)
      study_type = codes.filter_map { |code| StudyType.find_by(code: code.to_s.strip) }.first
      conversation.update!(study_type: study_type) if study_type
    end
end
