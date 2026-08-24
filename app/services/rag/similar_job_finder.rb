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
  #
  # CALIBRAGEM. A versão anterior pontuava pela similaridade bruta, e num acervo de domínio único
  # isso quase não discrimina: medido aqui, uma receita de bolo tirava 0,51 e uma frase genérica
  # sobre consultoria ambiental tirava 0,68 — contra o corte de 0,60 que existia. Numa proposta
  # de BESS para a Rio Energy o sistema anunciou "73% semelhante" a um job de execução de PBA,
  # sendo que dois dos três trechos que geraram o número eram a CAPA da proposta antiga, e o
  # acervo não tem nenhum projeto de BESS.
  #
  # O que separa sinal de ruído, medido contra consultas de resposta conhecida, são duas coisas
  # que a similaridade média não captura:
  #
  #   1. MARGEM sobre o piso do acervo (Rag::CorpusFloor) — quanto sobra depois de descontar o
  #      que qualquer texto do domínio já pontua.
  #   2. DOMÍNIO da cabeça do ranking — quando existe um projeto de verdade, ele ocupa quase
  #      todos os primeiros lugares (seminários: 5 de 5; plantio: 5 de 5). Quando não existe, a
  #      cabeça se espalha por uma dúzia de jobs, e cada um deles é coincidência.
  class SimilarJobFinder
    # Busca ampla antes de agregar: um job semelhante costuma casar em várias seções (objetivo,
    # escopo, produtos), e é essa recorrência que a agregação mede.
    CANDIDATE_CHUNKS = 40

    # Os primeiros colocados, onde o domínio é medido. Curto de propósito: é a cabeça do ranking
    # que distingue um projeto de verdade de um parágrafo coincidente.
    HEAD_CHUNKS = 10

    # Quantos trechos entram na força de cada job. Usar só o melhor premia coincidência isolada;
    # usar todos dilui um job realmente próximo que casou forte em poucas seções.
    SCORING_CHUNKS = 3

    # Na prática o corte de domínio já limita a 2 (dois jobs não somam mais que 1,0 da cabeça).
    MAX_JOBS = 3

    # Os cortes abaixo foram medidos contra oito consultas de resposta conhecida — quatro que
    # DEVEM achar um job específico e quatro que não devem achar nada. Nenhum dos dois sinais
    # separa sozinho; juntos, separam os oito casos:
    #
    #   consulta                    domínio  força    deve achar?
    #   bolo de fubá                   0,3   -0,05    não
    #   migração de PostgreSQL         0,4   -0,08    não
    #   "consultoria ambiental" (vaga) 0,8   -0,31    não   <- passa no domínio, morre na força
    #   BESS / conversa 93             0,4   -0,36    não
    #   quilombola                     0,5   -0,05    sim (25051)
    #   plantio compensatório          0,6   -0,11    sim (25010)
    #   inventário florestal           0,6   -0,13    sim (25015)
    #   seminários                     1,0   +0,18    sim (25068)
    #
    # Refazer esta tabela ao mexer no chunking, no modelo de embedding ou no acervo — os cortes
    # são empíricos, não têm significado fora dessas medições.
    MIN_DOMINANCE = 0.5
    MIN_STRENGTH = -0.20

    # Acima disto o job é referência direta: manda em quase toda a cabeça do ranking E está
    # praticamente no nível do acervo médio. Abaixo, é ponto de partida parcial, e a mensagem
    # para o consultor diz isso em vez de sugerir equivalência.
    STRONG_DOMINANCE = 0.7
    STRONG_STRENGTH = -0.05

    Match = Data.define(:job_number, :client_name, :subject, :year, :strength, :dominance,
                        :sections, :documents) do
      def label = [ job_number, client_name, subject ].compact_blank.join(" · ")

      def strong? = dominance >= STRONG_DOMINANCE && strength >= STRONG_STRENGTH

      # O que o consultor lê. Porcentagem de similaridade saiu de propósito: a faixa útil inteira
      # cabe entre 0,68 e 0,75 neste acervo, então o número comunica uma precisão que não existe.
      def confidence_label = strong? ? "referência direta" : "aproveitável em parte"
    end

    def initialize(retriever: nil, floor: nil, embedder: nil)
      @embedder = embedder || Embedder.new
      @retriever = retriever || Retriever.new(embedder: @embedder)
      @floor = floor || CorpusFloor.new
    end

    # context: descritor do serviço desta proposta (ver GenerateSummaryJob#service_descriptor).
    # Devolve [] quando o acervo não tem nada parecido — que é uma resposta legítima, e a que
    # faltava: antes o corte garantia três sugestões sempre.
    def call(context, limit: MAX_JOBS)
      return [] if context.to_s.strip.blank?

      vector = @embedder.embed_query(context.to_s.strip)
      hits = @retriever.hits_for(
        vector,
        roles: DocumentClassifier::VOICE_OF_PAPYRUS,
        limit: CANDIDATE_CHUNKS,
        include_boilerplate: false,
        include_sensitive: true # a proposta inteira conta como candidata; o que é exposto depois é escolha de quem consome
      )
      return [] if hits.empty?

      group(hits, @floor.call(vector)).first(limit)
    end

    private

    def group(hits, floor)
      head = hits.first(HEAD_CHUNKS).map { |hit| job_key(hit) }

      hits.group_by { |hit| job_key(hit) }
        .filter_map { |key, group| build_match(group, floor, head.count(key) / HEAD_CHUNKS.to_f) }
        .select { |match| match.dominance >= MIN_DOMINANCE && match.strength >= MIN_STRENGTH }
        .sort_by { |match| [ -match.dominance, -match.strength ] }
    end

    # Um job pode ter mais de uma proposta (revisões, propostas por frente de serviço), então a
    # chave é o número do job — não o documento.
    def job_key(hit)
      proposal = hit.chunk.historical_proposal
      proposal.job_number.presence || proposal.job_name
    end

    def build_match(group, floor, dominance)
      first = group.first.chunk.historical_proposal
      top = group.max_by(SCORING_CHUNKS, &:similarity)

      Match.new(
        job_number: first.job_number,
        client_name: first.client_name,
        subject: first.subject,
        year: first.year,
        strength: (top.sum { |hit| floor.adjust(hit.similarity) } / top.size).round(4),
        dominance: dominance.round(2),
        sections: group.filter_map { |hit| hit.section.presence }.uniq.first(8),
        documents: group.map { |hit| hit.chunk.historical_proposal.filename }.uniq
      )
    end
  end
end
