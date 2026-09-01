class ProcessLegalNormsJob < ApplicationJob
  queue_as :default

  # Roda ENTRE et e tr (nunca em paralelo com nenhum dos dois — ver Conversation::PROCESSING_STEPS
  # e ProcessEtJob#advance_after_et!): o âmbito certo pra pesquisar no CAL (municipal/estadual/
  # federal) só se sabe depois que o ET identifica o(s) município(s) do empreendimento, e o
  # resultado dessa pesquisa precisa estar disponível ANTES do TR ser lido — pra a IA já saber o
  # que a legislação exige quando cruzar com o que o TR institucional pede.
  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    municipios = conversation.project_findings.active.where(field: "municipios").pluck(:value)
    return conversation.mark_step!("cal", "skipped") if municipios.empty?

    conversation.mark_step!("cal", "running")

    # Esta é a chamada que efetivamente USA a ferramenta pela primeira vez nesta conversa —
    # precisa registrar explicitamente. Daí em diante, Conversation#ask_internally já registra
    # sozinho em qualquer chamada seguinte, sempre que detectar histórico de uso de tool.
    conversation.with_tool(SearchLegalNormsTool.new)
    conversation.ask_internally(prompt(conversation, municipios), hide_response: true)
    record_findings!(conversation)

    conversation.mark_step!("cal", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessLegalNormsJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("cal", "failed")
  ensure
    if conversation
      ProcessTrJob.perform_later(conversation.id) if conversation.processing_step_status("tr") == "pending"
      conversation.check_processing_complete!
    end
  end

  private
    # Diferente de ProcessEtJob/ProcessTrJob/ProcessCompDocsJob, esta chamada REGISTRA a
    # ferramenta search_legal_norms (ver #perform) — a IA decide sozinha quantas buscas fazer e
    # quando pedir o texto completo de uma norma, em vez de extrair achados de um texto já anexado.
    def prompt(conversation, municipios)
      tipo_estudo = conversation.study_type&.name
      orgao = conversation.project_findings.active.where(field: "orgao_ambiental").pluck(:value).first
      fields = ProjectFinding::FIELDS.map { |key, config| "- #{key}: #{config[:label]}" }.join("\n")

      <<~TEXT
        Pesquise no CAL (ferramenta search_legal_norms) a legislação ambiental aplicável a este
        projeto, pra fundamentar o escopo e as referências legais da proposta antes mesmo do TR
        ser lido.

        Município(s) do empreendimento: #{municipios.join(', ')}
        #{"Tipo de estudo já identificado: #{tipo_estudo}" if tipo_estudo}
        #{"Órgão ambiental já identificado: #{orgao}" if orgao}

        Regra pra decidir o âmbito da busca:
        - Se o projeto abrange MAIS DE UM município, pesquise âmbito ESTADUAL ou FEDERAL — uma
          norma municipal não vale pra um projeto que atravessa município. Decida qual dos dois
          com base no órgão ambiental já identificado (estadual → INEMA/SEMAD/CETESB e
          equivalentes; federal → IBAMA) e no que a busca no CAL mostrar.
        - Se for um ÚNICO município, considere qualquer âmbito que se aplique de verdade àquele
          local — municipal, estadual ou federal — e escolha a norma que realmente rege o caso.

        Use a ferramenta search_legal_norms quantas vezes precisar: por palavra-chave pra
        descobrir normas candidatas, e por codigo_norma pra ler o texto completo antes de afirmar
        o que uma norma exige — não conclua só pelo resumo da busca.

        Devolva o que encontrou como uma LISTA DE ACHADOS, no mesmo formato já usado nesta
        conversa. Campos disponíveis (use exatamente estas chaves; uma exigência legal encontrada
        no CAL normalmente é "condicionantes" — a norma exige algo do estudo):
        #{fields}

        Cada achado: "campo", "valor" (a exigência em si, citando a norma — ex.: "Portaria INEMA
        11.292/16 exige Estudo Ambiental para Atividades de Médio Impacto (EMI) para
        empreendimentos Classe 3, 4 ou 5"), "natureza" ("fato" quando o trecho comprova, nunca
        quando você só supôs), "trecho" (texto LITERAL da norma, nunca parafraseado) e "local" (a
        "referencia" que a própria ferramenta já devolve pronta em cada resultado, ex.: "NL7484 —
        Portaria 11292/16, INEMA, Estadual (CAL/Ius Natura)").

        Se a pesquisa não encontrar nada relevante ou aplicável, devolva a lista de achados vazia
        — nunca invente uma norma que a busca não confirmou.

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "achados": [
            {
              "campo": "condicionantes",
              "valor": "...",
              "natureza": "fato",
              "trecho": "...",
              "local": "..."
            }
          ]
        }
      TEXT
    end

    def record_findings!(conversation)
      reply = conversation.messages.where(role: "assistant").order(:created_at).last
      return unless reply

      ProjectFindings::Recorder.new(conversation, source_kind: "cal").call(AiJsonResponse.parse(reply.content))
    end
end
