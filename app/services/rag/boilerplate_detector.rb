module Rag
  # Marca os trechos que se repetem entre jobs — o texto de modelo da proposta da Papyrus.
  #
  # Existe por um caso concreto: numa proposta de BESS para a Rio Energy, o acervo devolveu como
  # "73% semelhante" um job de execução de PBA, e dois dos três trechos que produziram esse score
  # eram a CAPA da proposta antiga ("A Rio Energy Att.: Sr. ... Ref.: Proposta de Serviço").
  # Obrigações das partes, validade, prazo e condições de pagamento são idênticos em toda
  # proposta: não informam nada sobre QUAL job é, mas disputavam a recuperação com o escopo.
  #
  # O critério é frequência entre jobs, não similaridade com um vizinho só — é a ideia de IDF
  # aplicada a trecho. Texto copiado entre duas propostas do mesmo cliente é reuso legítimo de
  # escopo e continua recuperável; texto presente em um quinto do acervo é formulário.
  #
  # O que NÃO é marcado, de propósito: o Preâmbulo. Ele carrega o "Ref.: Proposta Técnica para
  # ..." — muitas vezes a frase que melhor descreve o job. O que atraía a capa errada era o nome
  # do cliente na CONSULTA (ver GenerateSummaryJob#search_context), não a capa estar indexada.
  class BoilerplateDetector
    # Distância cosseno abaixo da qual dois trechos são "o mesmo texto" para este fim. Frouxa de
    # propósito: a capa e as obrigações variam em nome, data e número sem mudar de natureza.
    NEAR_DISTANCE = 0.20

    # Em quantos OUTROS jobs o trecho precisa aparecer. Fração do acervo em vez de número fixo,
    # para o critério não afrouxar sozinho conforme o acervo cresce.
    MIN_JOB_SHARE = 0.20
    MIN_JOBS = 3

    Result = Data.define(:examined, :marked, :cleared, :threshold) do
      def to_s
        "#{examined} trechos examinados, #{marked} marcados como repetidos, #{cleared} desmarcados " \
        "(presentes em #{threshold}+ outros jobs)"
      end
    end

    def initialize(roles: DocumentClassifier::VOICE_OF_PAPYRUS)
      @roles = roles
    end

    def call
      threshold = job_threshold
      counts = cross_job_counts

      repeated, distinct = counts.partition { |_id, jobs| jobs >= threshold }.map { |pairs| pairs.map(&:first) }

      marked = update_flag(repeated, true)
      cleared = update_flag(distinct, false)

      Result.new(examined: counts.size, marked: marked, cleared: cleared, threshold: threshold)
    end

    private

    def job_threshold
      [ (total_jobs * MIN_JOB_SHARE).ceil, MIN_JOBS ].max
    end

    def total_jobs
      HistoricalProposal.current.where(role: @roles)
        .distinct.count(Arel.sql("COALESCE(job_number, job_name)"))
    end

    # Em quantos outros jobs cada trecho tem um quase-idêntico. O acervo é pequeno (centenas de
    # trechos na voz da Papyrus), então a comparação de todos contra todos roda no banco em um
    # passe só e dispensa índice aproximado — que aqui atrapalharia, por ser aproximado.
    def cross_job_counts
      ActiveRecord::Base.connection.select_rows(<<~SQL.squish).to_h { |id, jobs| [ id.to_i, jobs.to_i ] }
        WITH voice AS (
          SELECT c.id, c.embedding, COALESCE(hp.job_number, hp.job_name) AS job
          FROM historical_proposal_chunks c
          JOIN historical_proposals hp ON hp.id = c.historical_proposal_id
          WHERE hp.role IN (#{quoted_roles}) AND hp.superseded = false AND c.embedding IS NOT NULL
        )
        SELECT a.id,
               (SELECT COUNT(DISTINCT b.job) FROM voice b
                WHERE b.job IS DISTINCT FROM a.job AND (a.embedding <=> b.embedding) < #{NEAR_DISTANCE})
        FROM voice a
      SQL
    end

    def quoted_roles
      @roles.map { |role| ActiveRecord::Base.connection.quote(role) }.join(", ")
    end

    def update_flag(ids, value)
      return 0 if ids.empty?

      HistoricalProposalChunk.where(id: ids).where.not(boilerplate: value).update_all(boilerplate: value)
    end
  end
end
