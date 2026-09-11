require "test_helper"

class SearchLegalNormsArchiveToolTest < ActiveSupport::TestCase
  class FakeEmbedder
    def initialize(vector)
      @vector = vector
    end

    def embed_query(_text) = @vector
  end

  CLOSE_VECTOR = Array.new(Rag::Embedder::DIMENSIONS, 0.1).freeze
  # Ortogonal ao CLOSE_VECTOR (produto escalar zero em dimensão par) — distância de cosseno 1,
  # bem acima do corte MAX_DISTANCE.
  FAR_VECTOR = Array.new(Rag::Embedder::DIMENSIONS) { |i| i.even? ? 1.0 : -1.0 }.freeze

  def create_chunk(vector:, content: "Trecho de teste", codigo: "NL#{SecureRandom.hex(4)}", embedded_at: Time.current)
    norma = LegalNorm.create!(
      codigo: codigo, tipo_e_numero: "Resolução X", orgao: "INEMA", ambito: "Estadual",
      assunto: "Assunto de teste", referencia: "#{codigo} — Resolução X, INEMA (CAL/Ius Natura)"
    )
    norma.chunks.create!(position: 0, content: content, embedding: vector, embedding_model: "test", embedded_at: embedded_at)
  end

  test "busca vazia é recusada sem chamar o embedder" do
    tool = SearchLegalNormsArchiveTool.new(embedder: FakeEmbedder.new(CLOSE_VECTOR))

    result = JSON.parse(tool.execute(busca: "   "))

    assert result["error"].present?
  end

  test "devolve trechos parecidos com referência pronta pra citar" do
    create_chunk(vector: CLOSE_VECTOR, content: "Exige inventário florestal antes da supressão de vegetação.")
    tool = SearchLegalNormsArchiveTool.new(embedder: FakeEmbedder.new(CLOSE_VECTOR))

    result = JSON.parse(tool.execute(busca: "inventário florestal"))

    assert_equal 1, result["resultados"].size
    resultado = result["resultados"].first
    assert_includes resultado["trecho"], "inventário florestal"
    assert_includes resultado["referencia"], "CAL/Ius Natura"
    assert_equal "INEMA", resultado["origem"]["orgao"]
    assert result["instrucao"].present?
  end

  test "corpus vazio devolve aviso, não erro" do
    tool = SearchLegalNormsArchiveTool.new(embedder: FakeEmbedder.new(CLOSE_VECTOR))

    result = JSON.parse(tool.execute(busca: "qualquer coisa"))

    assert_empty result["resultados"]
    assert result["aviso"].present?
    assert_nil result["error"]
  end

  test "trecho longe demais do corte de similaridade não aparece" do
    create_chunk(vector: FAR_VECTOR)
    tool = SearchLegalNormsArchiveTool.new(embedder: FakeEmbedder.new(CLOSE_VECTOR))

    result = JSON.parse(tool.execute(busca: "algo sem relação nenhuma"))

    assert_empty result["resultados"]
  end

  test "não busca em chunk que ainda não foi embedado" do
    create_chunk(vector: nil, embedded_at: nil)
    tool = SearchLegalNormsArchiveTool.new(embedder: FakeEmbedder.new(CLOSE_VECTOR))

    result = JSON.parse(tool.execute(busca: "qualquer coisa"))

    assert_empty result["resultados"]
  end
end
