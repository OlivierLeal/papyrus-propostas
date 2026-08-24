require "test_helper"

class Rag::CorpusFloorTest < ActiveSupport::TestCase
  test "o piso é a semelhança da consulta com a média do acervo" do
    chunk_for(angle: 1.0)
    chunk_for(angle: 1.0)

    # Consulta idêntica aos trechos: o acervo inteiro aponta para o mesmo lado, então tudo que
    # ele devolve é "média do acervo" e nada é específico.
    assert_in_delta 1.0, Rag::CorpusFloor.new.call(vector(1.0)).similarity, 0.001
  end

  test "o texto de modelo não entra no piso, porque também não entra na busca" do
    chunk_for(angle: 1.0, boilerplate: true)
    chunk_for(angle: 0.0)

    assert_in_delta 0.0, Rag::CorpusFloor.new.call(vector(1.0)).similarity, 0.001
  end

  test "acervo vazio devolve piso zero em vez de quebrar" do
    assert_equal 0.0, Rag::CorpusFloor.new.call(vector(1.0)).similarity
  end

  test "renormaliza a similaridade sobre o piso" do
    floor = Rag::CorpusFloor::Floor.new(similarity: 0.70)

    assert_in_delta 1.0, floor.adjust(1.0), 0.0001
    assert_in_delta 0.0, floor.adjust(0.70), 0.0001, "no piso, o trecho não distingue nada"
    assert_operator floor.adjust(0.68), :<, 0, "abaixo do piso é menos parecido que o acervo médio"
  end

  private

  def vector(angle)
    v = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    v[0] = angle
    v[1] = Math.sqrt([ 1 - (angle**2), 0 ].max)
    v
  end

  def chunk_for(angle:, boilerplate: false)
    seed = "#{angle}-#{boilerplate}-#{SecureRandom.hex(4)}"
    proposal = HistoricalProposal.create!(
      job_name: "25001_Cliente", job_number: "25001", client_name: "Cliente",
      source_path: "/x/#{seed}", relative_path: seed, filename: "#{seed}.docx",
      source_sha256: Digest::SHA256.hexdigest(seed), chunker_version: Rag::Indexer::PIPELINE_VERSION,
      role: "proposta_papyrus", role_source: "ai", status: "ok"
    )

    proposal.chunks.create!(
      position: 0, content: seed, boilerplate: boilerplate,
      embedding: vector(angle), embedded_at: Time.current, embedding_model: Rag::Embedder::MODEL_ID
    )
  end
end
