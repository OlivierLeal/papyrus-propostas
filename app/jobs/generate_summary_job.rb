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

        #{legal_framing_summary(conversation)}

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
    # Com as fichas de precedente (JobPrecedent) cobrindo o acervo, a comparação é JOB contra JOB
    # (descritor x descritor, mesmo formato) — mais limpa que trecho contra trecho, cuja calibragem
    # (dominância da cabeça do ranking) quebra quando o assunto se divide entre vários jobs
    # parecidos (avaliação de 2026-09-27: BESS+solar com 8 jobs certos na cabeça, "nenhum
    # semelhante" no resumo). Sem fichas suficientes, segue o método por trechos.
    PRECEDENT_COVERAGE = 50

    def similar_jobs_summary(conversation)
      return precedents_summary(conversation) if JobPrecedent.searchable.count >= PRECEDENT_COVERAGE

      matches = Rag::SimilarJobFinder.new.call(conversation.service_descriptor)
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

    def precedents_summary(conversation)
      matches = Rag::PrecedentFinder.new.call(conversation.service_descriptor, limit: 3)
        .select { |match| match.similarity >= Rag::PrecedentFinder::PARTIAL_SIMILARITY }
      return nothing_similar_notice if matches.empty?

      lines = matches.map do |match|
        precedent = match.precedent
        facts = [
          (precedent.total_value && "valor da época #{ActiveSupport::NumberHelper.number_to_currency(precedent.total_value, unit: 'R$', separator: ',', delimiter: '.')}"),
          (precedent.team_members.any? && "equipe de #{precedent.team_members.size} pessoas"),
          (precedent.duration && "prazo #{precedent.duration.truncate(50)}")
        ].compact_blank.join(", ")
        "- #{precedent.reference} — #{precedent.service.to_s.truncate(150)} — #{match.confidence_label}#{"; #{facts}" if facts.present?}"
      end

      <<~TEXT
        Projetos semelhantes que a Papyrus já executou (fichas do acervo histórico):
        #{lines.join("\n")}

        Informe isso ao consultor em um tópico próprio do resumo, dizendo que servirão de
        referência para estruturar esta proposta (a ferramenta search_project_precedents traz a
        equipe completa). Valores são da época — referência de porte, nunca preço desta proposta.
        Não afirme que o escopo é idêntico — quem confirma isso é o consultor.
      TEXT
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

    # Pedido da Sara (2026-09-29): antes de gerar, o resumo diz "a legislação enquadra assim, o
    # cliente pediu assim, o que faço?". O enquadramento pela lei vem do CAL (ProcessLegalNormsJob);
    # o pedido, do ET/TR. Quando concordam, o resumo confirma; quando o CAL não conseguiu concluir,
    # diz isso em vez de calar — "não verificado" é diferente de "confere".
    def legal_framing_summary(conversation)
      findings = conversation.project_findings.active.includes(:source_blob)
      legal = findings.select { |f| f.source_kind == "cal" && (f.field == "enquadramento_legal" || ProjectFinding::FRAMING_FIELDS.include?(f.field)) }
      requested = findings.select { |f| f.source_kind != "cal" && ProjectFinding::FRAMING_FIELDS.include?(f.field) }
      conflicts = conversation.project_conflicts.open.includes(findings: :source_blob).select(&:legal_framing?)

      if legal.empty?
        return <<~TEXT
          ENQUADRAMENTO LEGAL: a pesquisa na legislação (CAL) não chegou a um enquadramento para este
          projeto (sem município identificado, CAL indisponível, ou a norma não permitiu concluir).
          Abra um tópico "Enquadramento legal" dizendo isso em uma frase, e que o enquadramento
          pedido pelo cliente NÃO foi conferido contra a legislação — cabe ao consultor confirmar.
        TEXT
      end

      <<~TEXT
        ENQUADRAMENTO LEGAL × O QUE FOI SOLICITADO:
        Pela legislação (CAL):
        #{legal.map(&:to_context_line).join("\n")}
        Solicitado nos documentos do cliente:
        #{requested.map(&:to_context_line).join("\n").presence || "- nada sobre licença/estudo"}
        #{conflicts.any? ? "O sistema encontrou divergência em: #{conflicts.map(&:field_label).join(', ')}." : "O sistema não encontrou divergência entre os dois."}

        Abra um tópico "Enquadramento legal" logo no início do resumo, em três partes curtas:
        "A legislação diz: …" (com a norma), "O cliente pediu: …" (com o documento), e, se houver
        divergência, "O que fazer:" — seguir a legislação, seguir o que foi pedido, ou levar ao
        cliente decidir; o card logo abaixo do resumo registra a escolha, e qualquer das três
        entra no texto da proposta. Não recomende um lado. Sem divergência, diga que a legislação
        confirma o que foi pedido.
      TEXT
    end

    # Divergência entre documentos é o tipo de coisa que passa despercebida numa leitura corrida e
    # reaparece depois como retrabalho. O sistema não escolhe um lado — mostra os dois.
    def conflicts_summary(conversation)
      conflicts = conversation.project_conflicts.open.includes(findings: :source_blob).reject(&:legal_framing?)
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
      conflicts.sort_by { |conflict| conflict.legal_framing? ? 0 : 1 }.each do |conflict|
        conversation.messages.create!(role: "assistant", content: { project_conflict_id: conflict.id }.to_json)
      end
    end
end
