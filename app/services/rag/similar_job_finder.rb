module Rag
  # Descobre se a Papyrus já fez um projeto parecido com o desta conversa.
  #
  # Diferente do Rag::Retriever, que devolve trechos soltos para responder uma pergunta, aqui a
  # unidade de resposta é o PROJETO: "já fizemos isto para a Petrobras em 2025, na proposta
  # 25001". É o caso de uso que o consultor tem na cabeça ao abrir uma proposta nova — mesmo
  # serviço, outra área — e que não depende de ele lembrar de perguntar.
  #
  # A busca é feita só sobre a voz da Papyrus: o que interessa é achar uma PROPOSTA parecida
  # para usar de modelo, não um TR de cliente parecido.
  class SimilarJobFinder
    # Busca ampla de trechos antes de agregar: um job semelhante costuma casar em várias seções
    # (objetivo, escopo, produtos), e é essa recorrência que distingue "parecido de verdade" de
    # "um parágrafo que por acaso bateu".
    CANDIDATE_CHUNKS = 40

    # Abaixo disto a semelhança é genérica — dois estudos ambientais quaisquer compartilham
    # vocabulário suficiente para pontuar algo. Só vale sugerir o que é de fato aproveitável.
    MIN_SCORE = 0.60

    MAX_JOBS = 3
    # Quantos trechos entram no score de cada job. Usar só o melhor premia coincidência isolada;
    # usar todos dilui um job realmente próximo que casou forte em poucas seções.
    SCORING_CHUNKS = 3

    # Peso mínimo de um job que casou em uma seção só. Sem isso, a média sozinha deixa um único
    # parágrafo com 0,80 vencer um projeto que bateu em três seções com 0,78 cada — e é o
    # segundo que serve de modelo para escrever uma proposta inteira. Quem casa em objetivo,
    # escopo E equipe é parecido de verdade; quem casa num parágrafo é coincidência.
    COVERAGE_FLOOR = 0.6

    Match = Data.define(:job_number, :client_name, :subject, :year, :score, :sections, :documents) do
      def label = [ job_number, client_name, subject ].compact_blank.join(" · ")
    end

    def initialize(retriever: nil)
      @retriever = retriever || Retriever.new
    end

    # context: texto que descreve o projeto atual (tipo de estudo, empreendimento, escopo).
    def call(context, limit: MAX_JOBS)
      return [] if context.to_s.strip.blank?

      hits = @retriever.call(
        context.to_s.strip,
        roles: DocumentClassifier::VOICE_OF_PAPYRUS,
        limit: CANDIDATE_CHUNKS,
        include_sensitive: true  # a proposta inteira conta como candidata; o que é exposto depois é escolha de quem consome
      )

      group(hits).select { |match| match.score >= MIN_SCORE }.first(limit)
    end

    private

    def group(hits)
      hits.group_by { |hit| job_key(hit) }
        .filter_map { |_key, group| build_match(group) }
        .sort_by { |match| -match.score }
    end

    # Similaridade média dos melhores trechos, descontada pela cobertura: um job precisa casar
    # em várias seções para valer como referência de proposta inteira.
    def score_for(top)
      average = top.sum(&:similarity) / top.size
      coverage = COVERAGE_FLOOR + ((1 - COVERAGE_FLOOR) * top.size / SCORING_CHUNKS.to_f)

      (average * [ coverage, 1.0 ].min).round(4)
    end

    # Um job pode ter mais de uma proposta (revisões, propostas por frente de serviço), então a
    # chave é o número do job — não o documento.
    def job_key(hit)
      proposal = hit.chunk.historical_proposal
      proposal.job_number.presence || proposal.job_name
    end

    def build_match(group)
      first = group.first.chunk.historical_proposal
      top = group.max_by(SCORING_CHUNKS, &:similarity)

      Match.new(
        job_number: first.job_number,
        client_name: first.client_name,
        subject: first.subject,
        year: first.year,
        score: score_for(top),
        sections: group.filter_map { |hit| hit.section.presence }.uniq.first(8),
        documents: group.map { |hit| hit.chunk.historical_proposal.filename }.uniq
      )
    end
  end
end
