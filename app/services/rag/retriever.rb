module Rag
  # Etapa 6: busca por similaridade no acervo.
  #
  # O filtro por papel é o que dá sentido ao resultado. "Como a Papyrus descreve o escopo de um
  # EIA-RIMA" precisa buscar SÓ em proposta_papyrus; "que exigências o cliente fez" precisa
  # buscar em tr_cliente. Sem separar, o texto do cliente — que costuma ser mais volumoso que
  # a proposta — domina a recuperação e o RAG passa a ensinar a IA a imitar o cliente.
  class Retriever
    DEFAULT_LIMIT = 5

    # Acima desta distância cosseno o trecho não tem relação real com a pergunta; devolver
    # assim mesmo só gasta contexto do Prompt 2 com ruído.
    MAX_DISTANCE = 0.75

    Hit = Data.define(:chunk, :distance) do
      def similarity = (1 - distance).round(4)
      def source = chunk.source_label
      def section = [ chunk.section_number, chunk.section_title ].compact_blank.join(". ")
    end

    def initialize(embedder: nil)
      @embedder = embedder || Embedder.new
    end

    # roles: restringe a papéis (default: só a voz da Papyrus, ver comentário da classe).
    # include_sensitive: por padrão, trechos com dado identificável ficam fora (LGPD).
    def call(query, roles: DocumentClassifier::VOICE_OF_PAPYRUS, limit: DEFAULT_LIMIT,
             include_sensitive: false, client_name: nil)
      vector = @embedder.embed_query(query)

      # O filtro usa o nome real da tabela (plural) porque `indexable` entra por joins; um
      # `includes` aqui criaria o alias singular e as duas referências brigariam no SQL.
      scope = HistoricalProposalChunk.embedded.indexable
      scope = scope.where(historical_proposals: { role: roles }) if roles.present?
      scope = scope.where(historical_proposals: { client_name: client_name }) if client_name.present?
      scope = scope.without_sensitive unless include_sensitive

      scope
        .nearest_neighbors(:embedding, vector, distance: "cosine")
        .preload(:historical_proposal)
        .limit(limit)
        .filter_map { |chunk| build_hit(chunk) }
    end

    private

    def build_hit(chunk)
      distance = chunk.neighbor_distance
      return nil if distance.nil? || distance > MAX_DISTANCE

      Hit.new(chunk: chunk, distance: distance.round(4))
    end
  end
end
