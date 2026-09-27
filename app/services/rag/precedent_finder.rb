module Rag
  # Acha os jobs do acervo mais parecidos com um descritor de serviço (normalmente
  # Conversation#service_descriptor) comparando com o descritor de cada JobPrecedent.
  class PrecedentFinder
    DEFAULT_LIMIT = 3
    # Descritor contra descritor (mesmo formato dos dois lados) discrimina melhor que trecho
    # contra consulta; acima disto não é o mesmo tipo de serviço.
    MAX_DISTANCE = 0.45

    # Cortes pro resumo ("projetos semelhantes"), medidos na amostra de 2026-09-27 (40 fichas):
    # descritor rico de BESS+solar → 0,75-0,76 com LP de usina solar; descritor pobre ("tipo
    # estudo: RAP") → 0,57-0,60 com qualquer coisa. Refazer com script/rag/eval.rb depois da
    # extração completa (e ao trocar modelo de embedding).
    STRONG_SIMILARITY = 0.75
    PARTIAL_SIMILARITY = 0.68

    # Descritor só com "tipo estudo: X" casa com qualquer job do mesmo tipo — não é "parecido".
    # Exige o que de fato distingue um serviço: o empreendimento ou os diagnósticos.
    DISTINCTIVE_FIELDS = %w[empreendimento diagnosticos].freeze

    Match = Data.define(:precedent, :similarity) do
      def strong? = similarity >= STRONG_SIMILARITY
      def confidence_label = strong? ? "referência direta" : "aproveitável em parte"
    end

    def self.distinctive?(descriptor)
      descriptor.to_s.lines.any? { |line| DISTINCTIVE_FIELDS.include?(line.split(":").first.to_s.strip) }
    end

    def initialize(embedder: nil)
      @embedder = embedder || Embedder.new
    end

    def call(descriptor, limit: DEFAULT_LIMIT, exclude_job: nil)
      return [] if descriptor.blank? || !self.class.distinctive?(descriptor) || !JobPrecedent.searchable.exists?

      vector = @embedder.embed_query(descriptor)
      scope = JobPrecedent.searchable
      scope = scope.where.not(job_number: exclude_job) if exclude_job.present?

      VectorScan.with_filtered_scan do
        scope.nearest_neighbors(:embedding, vector, distance: "cosine").limit(limit).filter_map do |precedent|
          distance = precedent.neighbor_distance
          Match.new(precedent: precedent, similarity: (1 - distance).round(3)) if distance && distance <= MAX_DISTANCE
        end
      end
    end
  end
end
