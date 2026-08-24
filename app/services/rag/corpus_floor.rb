module Rag
  # O piso de semelhança do acervo: quanto uma consulta já pontua só por ser um texto de
  # consultoria ambiental em português.
  #
  # Num acervo de domínio único o cosseno entre dois textos quaisquer parte alto, e a faixa que
  # separa "parecido" de "qualquer coisa" é estreita. Medido neste acervo: uma receita de bolo
  # pontua 0,51; uma frase sobre migração de PostgreSQL, 0,60; a frase vazia "serviços de
  # consultoria ambiental para licenciamento", 0,68. O corte de 0,60 que existia antes aceitava
  # a consulta sobre banco de dados.
  #
  # O piso é a similaridade da consulta com o CENTROIDE do acervo — o vetor "proposta genérica da
  # Papyrus". Descontá-lo devolve o que sobra de específico. Quando nenhum trecho supera o piso,
  # a consulta está mais perto da média do acervo do que de qualquer documento dele: é a forma
  # medível de "não tem nada parecido aqui".
  class CorpusFloor
    Floor = Data.define(:similarity) do
      # Similaridade renormalizada: 0 = indistinguível da média do acervo, 1 = idêntico.
      # Negativo quando o trecho é MENOS parecido com a consulta do que o acervo médio.
      def adjust(chunk_similarity)
        return chunk_similarity if similarity >= 1.0

        ((chunk_similarity - similarity) / (1 - similarity)).round(4)
      end
    end

    def initialize(roles: DocumentClassifier::VOICE_OF_PAPYRUS)
      @roles = roles
    end

    # Só o material recuperável entra no centroide: o piso precisa representar o que a busca
    # pode devolver, e o boilerplate está fora dela (ver Rag::BoilerplateDetector).
    def call(query_vector)
      distance = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ <<~SQL.squish, vector_literal(query_vector) ])
          SELECT (
            SELECT avg(c.embedding) FROM historical_proposal_chunks c
            JOIN historical_proposals hp ON hp.id = c.historical_proposal_id
            WHERE hp.role IN (#{quoted_roles}) AND hp.superseded = false
              AND c.embedding IS NOT NULL AND c.boilerplate = false
          ) <=> ?::vector
        SQL
      )

      Floor.new(similarity: distance.nil? ? 0.0 : (1 - distance).round(4))
    end

    private

    def vector_literal(query_vector) = "[#{query_vector.join(',')}]"

    def quoted_roles
      @roles.map { |role| ActiveRecord::Base.connection.quote(role) }.join(", ")
    end
  end
end
