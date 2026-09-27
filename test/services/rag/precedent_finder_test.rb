require "test_helper"

class Rag::PrecedentFinderTest < ActiveSupport::TestCase
  test "devolve os precedentes mais próximos dentro do limite, do mais parecido pro menos" do
    near = precedent("26098", 1.0)
    close = precedent("26063", 0.9)
    precedent("24001", 0.0) # ortogonal: longe demais

    matches = Rag::PrecedentFinder.new(embedder: FixedEmbedder.new(unit)).call("tipo estudo: EMI\nempreendimento: BESS")

    assert_equal [ near.job_number, close.job_number ], matches.map { |match| match.precedent.job_number }
    assert matches.first.similarity > matches.last.similarity
  end

  test "sem descritor ou sem ficha nenhuma, não chama o embedding" do
    assert_equal [], Rag::PrecedentFinder.new(embedder: nil).call("")
    assert_equal [], Rag::PrecedentFinder.new(embedder: nil).call("algo")
  end

  test "pode excluir o próprio job" do
    precedent("26098", 1.0)

    assert_empty Rag::PrecedentFinder.new(embedder: FixedEmbedder.new(unit)).call("empreendimento: BESS", exclude_job: "26098")
  end

  # Só "tipo estudo: RAP" casa com qualquer RAP do acervo (0,57-0,60 na amostra real) — não é
  # "parecido". Exige empreendimento ou diagnósticos.
  test "descritor sem empreendimento nem diagnósticos não compara" do
    precedent("26098", 1.0)

    assert_empty Rag::PrecedentFinder.new(embedder: nil).call("tipo estudo: RAP")
  end

  private

  def unit
    Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }.tap { |v| v[0] = 1.0 }
  end

  def precedent(job, x)
    embedding = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    embedding[0] = x
    embedding[1] = Math.sqrt([ 1 - (x**2), 0 ].max)
    JobPrecedent.create!(job_number: job, service: "serviço #{job}", embedding: embedding, status: "ok")
  end

  FixedEmbedder = Struct.new(:vector) do
    def embed_query(_text) = vector
  end
end
