class GenerateSummaryJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)

    # Antes do resumo: o que os documentos dizem já está registrado como achado, então dá para
    # comparar as fontes entre si e descobrir onde elas discordam (ver ProjectFindings::
    # ConflictDetector). O resumo precisa nascer sabendo disso.
    conflicts = ProjectFindings::ConflictDetector.new(conversation).call

    conversation.ask_internally(build_prompt(conversation))
    announce_conflicts(conversation, conflicts)

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

        Cada achado abaixo vem com um código entre colchetes (ex.: [F12]). Ao afirmar qualquer um
        deles no resumo, escreva o código logo depois da afirmação — o sistema o transforma num
        link que mostra ao consultor o trecho e o documento de onde a informação saiu. Use apenas
        os códigos listados; não invente código nem cite código para conclusão sua.

        Achados marcados como "Inferência" ou "Sugestão" NÃO foram lidos no documento: quem
        concluiu foi a IA. Apresente esses de forma explicitamente diferente dos fatos (ex.:
        "pelo porte do empreendimento, provavelmente..."), nunca como se o documento afirmasse.

        #{extracted_data_summary(conversation)}

        #{conflicts_summary(conversation)}

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

    # O campo "outro" (onde cai o que não coube no menu, inclusive o tipo do documento
    # complementar) fica FORA da consulta de propósito: é ali que aparece a carta de
    # encaminhamento ("Encaminhamento via Fulana da solicitação de Beltrano..."), exatamente o
    # vocabulário que puxava a recuperação para a capa das propostas antigas.

    def search_context(conversation)
      fields = conversation.project_findings.active.where(field: SEARCH_FIELDS.keys)
        .group_by(&:field)
        .transform_values { |findings| findings.map(&:value).compact_blank.uniq }
      # O código do tipo de estudo ("EIA-RIMA") diz menos que o nome cadastrado na hora de casar
      # com o texto de propostas antigas.
      fields["tipo_estudo"] = [ conversation.study_type.name ] if conversation.study_type

      SEARCH_FIELDS.filter_map do |field, budget|
        value = Array(fields[field]).map(&:to_s).compact_blank.join("; ")
        "#{field.tr('_', ' ')}: #{value.truncate(budget)}" if value.present?
      end.join("\n")
    end

    # Determinístico (KmzGeometryExtractor) — só informa o que já foi calculado, a IA não
    # recalcula nem estima área/perímetro por conta própria (CLAUDE.md seção 1).
    def geospatial_summary(conversation)
      result = conversation.geospatial_result
      return "" unless result

      "Dados geoespaciais do KMZ (já calculados pelo sistema): #{result.summary_text}"
    end

    # Os achados registrados na extração (ProjectFinding), agrupados por campo e já com o código
    # de citação de cada um. Substituiu o merge que reparseava todas as mensagens do assistente
    # atrás de JSON: ali a origem de cada informação se perdia no caminho, e é ela que o consultor
    # precisa para conferir.
    def extracted_data_summary(conversation)
      findings = conversation.project_findings.active.includes(:source_blob).order(:field, :id)
      return "Nenhum dado estruturado disponível ainda." if findings.empty?

      findings.group_by(&:field).map do |field, group|
        label = group.first.field_label
        "#{label}:\n#{group.map { |finding| finding.to_context_line }.join("\n")}"
      end.join("\n\n")
    end

    # Divergência entre documentos é o tipo de coisa que passa despercebida numa leitura corrida e
    # reaparece depois como retrabalho. O sistema não escolhe um lado — mostra os dois.
    def conflicts_summary(conversation)
      conflicts = conversation.project_conflicts.open.includes(findings: :source_blob)
      return "" if conflicts.empty?

      <<~TEXT
        DIVERGÊNCIAS ENTRE OS DOCUMENTOS (encontradas pelo sistema ao comparar as fontes):
        #{conflicts.map(&:to_context_line).join("\n")}

        Abra um tópico próprio no resumo para isso, listando cada divergência com os dois valores e
        de que documento veio cada um. NÃO escolha um dos valores e não sugira qual está certo —
        diga que o consultor precisa decidir, e que os cards logo abaixo do resumo permitem
        registrar a decisão. Isso não impede seguir com a proposta.
      TEXT
    end

    # Um card por divergência, no mesmo padrão do card de memória (KnowledgeNote): a mensagem
    # carrega só o id, e a view resolve o registro — assim o card reflete o estado atual mesmo
    # depois de o consultor decidir, sem reescrever histórico de conversa.
    def announce_conflicts(conversation, conflicts)
      conflicts.each do |conflict|
        conversation.messages.create!(role: "assistant", content: { project_conflict_id: conflict.id }.to_json)
      end
    end
end
