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

        #{client_memory_summary(conversation)}
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
      return nothing_similar_notice if matches.empty?

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

    # O que a Papyrus já aprendeu sobre ESTE cliente em propostas anteriores — aprovado por um
    # consultor, não inferido pela IA (ver KnowledgeNote). Entra sempre que houver, porque uma
    # exigência recorrente do cliente muda o escopo antes mesmo de a proposta começar.
    def client_memory_summary(conversation)
      notes = KnowledgeNote.approved.where(client_name: conversation.client_name)
        .where.not(conversation_id: conversation.id)
        .order(approved_at: :desc).limit(10)
      return "" if notes.empty?

      <<~TEXT
        O que a Papyrus já registrou sobre este cliente em projetos anteriores:
        #{notes.map { |note| "- [#{note.category_label}] #{note.content}" }.join("\n")}

        Considere isso ao montar o resumo e diga ao consultor que veio da memória do sistema.
      TEXT
    end

    # Sem porcentagem de propósito: neste acervo a faixa útil inteira cabe entre 0,68 e 0,75 de
    # similaridade, e uma frase vazia sobre consultoria ambiental já vale 0,68 — o número
    # comunicava uma precisão que não existe. Ver Rag::SimilarJobFinder.
    def format_match(match)
      "- #{match.label}#{" (#{match.year})" if match.year} — #{match.confidence_label}" \
      "#{"; seções aproveitáveis: #{match.sections.join(', ')}" if match.sections.any?}"
    end

    # "Não achei" é resposta, e é a que faltava: com o corte antigo o acervo sempre devolvia três
    # sugestões, então o consultor não tinha como distinguir achado de coincidência.
    def nothing_similar_notice
      <<~TEXT
        Busca no acervo histórico da Papyrus: nenhum projeto anterior semelhante o bastante para
        servir de modelo.

        Diga isso ao consultor em um tópico próprio, sem rodeios e sem sugerir projeto nenhum.
        Não significa que o acervo esteja vazio — significa que este serviço não tem precedente
        próximo lá dentro, e que a proposta será estruturada do zero.
      TEXT
    end

    # O que define "parecido" é o serviço, não o texto inteiro do TR: tipo de estudo,
    # empreendimento e escopo. Truncado porque o modelo de embedding corta em 512 tokens.
    # DESCRITOR DE SERVIÇO. O que define "parecido" é o serviço prestado, e mais nada.
    #
    # A versão anterior concatenava nome do cliente + o JSON extraído inteiro e cortava em 1500
    # caracteres. Isso embedava telefone, e-mail, prazo de manifestação de interesse e nome de
    # arquivo — vocabulário de CARTA, que puxa a recuperação para a capa das propostas antigas —
    # e o truncamento cego comia justamente as condicionantes e as ressalvas, que são o que
    # define escopo. O nome do cliente era o pior item: sozinho, "Rio Energy" já recupera a capa
    # da proposta endereçada à Rio Energy, e foi isso que fez um job sem relação virar o mais
    # parecido numa proposta de BESS.
    #
    # Cliente NÃO entra: é faceta de filtro, nunca semântica. Cada campo tem orçamento próprio,
    # para nenhum deles comer o espaço dos outros.
    SEARCH_FIELDS = {
      "tipo_licenca" => 120,
      "tipo_estudo" => 160,
      "orgao_ambiental" => 60,
      "municipios" => 120,
      "empreendimento" => 300,
      "diagnosticos" => 300,
      "condicionantes" => 500,
      "ressalvas" => 400
    }.freeze

    # O "resumo" do documento complementar NÃO entra como empreendimento: costuma ser a carta de
    # encaminhamento ("Encaminhamento via Fulana da solicitação de Beltrano..."), exatamente o
    # vocabulário que puxava a recuperação para a capa das propostas antigas. Quem descreve o
    # empreendimento é o campo próprio que o ProcessTrJob passou a extrair.
    FIELD_ALIASES = { "tipo_estudo_codigo" => "tipo_estudo" }.freeze

    def search_context(conversation)
      fields = extracted_fields(conversation)
      fields["tipo_estudo"] = conversation.study_type.name if conversation.study_type

      SEARCH_FIELDS.filter_map do |field, budget|
        value = Array(fields[field]).map(&:to_s).compact_blank.join("; ")
        "#{field.tr('_', ' ')}: #{value.truncate(budget)}" if value.present?
      end.join("\n")
    end

    def extracted_fields(conversation)
      conversation.messages.where(role: "assistant")
        .filter_map { |message| AiJsonResponse.parse(message.content) }
        .each_with_object({}) do |hash, merged|
          hash.each do |key, value|
            field = FIELD_ALIASES.fetch(key, key)
            next unless SEARCH_FIELDS.key?(field)

            merged[field] = Array(merged[field]).concat(Array(value)).compact_blank.uniq
          end
        end
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
