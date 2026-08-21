class GenerateSummaryJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)

    conversation.ask_internally(build_prompt(conversation))

    conversation.mark_step!("summary", "done")
    conversation.update!(status: "reviewing")
  rescue StandardError => e
    Rails.logger.error("GenerateSummaryJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("summary", "failed")
  end

  private
    def build_prompt(conversation)
      <<~TEXT
        Monte um resumo estruturado para o consultor da Papyrus revisar, com base nos dados já
        extraídos abaixo. Escreva em português, organizado em tópicos claros. Se alguma informação
        não estiver disponível, diga isso explicitamente em vez de inventar.

        #{extracted_data_summary(conversation)}

        #{geospatial_summary(conversation)}

        #{similar_jobs_summary(conversation)}
      TEXT
    end

    # Itens 4 e 9 do passo a passo interno ("pesquisar propostas anteriores semelhantes em
    # escopo", "consultar escopos e equipes já usados em serviços parecidos") acontecem AQUI,
    # sem depender de o consultor lembrar de perguntar. O caso real é justamente esse: o mesmo
    # serviço para o mesmo cliente em outra área — a proposta antiga é o melhor ponto de partida
    # que existe, e não adianta ela ficar no acervo se ninguém for buscá-la.
    #
    # Só os metadados do job entram no resumo; o texto das seções continua sendo buscado sob
    # demanda pela ferramenta search_historical_archive, na hora de escrever cada uma. Despejar
    # propostas inteiras aqui encheria o contexto de toda a conversa com material que talvez
    # não seja usado.
    def similar_jobs_summary(conversation)
      matches = Rag::SimilarJobFinder.new.call(search_context(conversation))
      return "" if matches.empty?

      <<~TEXT
        Projetos semelhantes que a Papyrus já executou (encontrados no acervo histórico):
        #{matches.map { |match| format_match(match) }.join("\n")}

        Informe isso ao consultor em um tópico próprio do resumo, dizendo que servirão de
        referência para estruturar esta proposta. Não afirme que o escopo é idêntico — quem
        confirma isso é o consultor.
      TEXT
    rescue StandardError => e
      # Acervo é um reforço, não um pré-requisito: falha aqui não pode impedir o resumo.
      Rails.logger.warn("[GenerateSummaryJob] busca de similares falhou: #{e.class} #{e.message}")
      ""
    end

    def format_match(match)
      "- #{match.label}#{" (#{match.year})" if match.year} — similaridade #{(match.score * 100).round}%" \
      "#{"; seções aproveitáveis: #{match.sections.join(', ')}" if match.sections.any?}"
    end

    # O que define "parecido" é o serviço, não o texto inteiro do TR: tipo de estudo,
    # empreendimento e escopo. Truncado porque o modelo de embedding corta em 512 tokens.
    def search_context(conversation)
      [ conversation.client_name, conversation.study_type&.name, extracted_data_summary(conversation) ]
        .compact_blank.join("\n").truncate(1500)
    end

    # Determinístico (KmzGeometryExtractor) — só informa o que já foi calculado, a IA não
    # recalcula nem estima área/perímetro por conta própria (CLAUDE.md seção 1).
    def geospatial_summary(conversation)
      result = conversation.geospatial_result
      return "" unless result

      "Dados geoespaciais do KMZ (já calculados pelo sistema): #{result.summary_text}"
    end

    def extracted_data_summary(conversation)
      parsed_findings = conversation.messages.where(role: "assistant").filter_map { |message| AiJsonResponse.parse(message.content) }
      return "Nenhum dado estruturado disponível ainda." if parsed_findings.empty?

      parsed_findings.map { |hash| format_hash(hash) }.join("\n\n")
    end

    def format_hash(hash)
      hash.map do |key, value|
        formatted_value = value.is_a?(Array) ? value.join("; ") : value
        "#{key}: #{formatted_value.presence || 'não informado'}"
      end.join("\n")
    end
end
