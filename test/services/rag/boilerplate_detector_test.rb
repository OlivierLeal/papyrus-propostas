require "test_helper"

class Rag::BoilerplateDetectorTest < ActiveSupport::TestCase
  # Vetores esparsos: a posição 0 controla o ângulo, então "quase idêntico" e "diferente" são
  # exatos no teste em vez de aproximados.
  IGUAIS = 0.999
  DIFERENTES = 0.5

  test "marca o trecho que se repete em muitos jobs e poupa o que é de um só" do
    5.times { |i| chunk_for("2500#{i}", "OBRIGAÇÕES DA PAPYRUS", angle: IGUAIS) }
    especifico = chunk_for("25099", "5. ESCOPO", angle: DIFERENTES)

    result = Rag::BoilerplateDetector.new.call

    assert_equal 6, result.examined
    assert_equal 5, result.marked
    assert_not especifico.reload.boilerplate, "trecho de um job só não é formulário"
  end

  # Reuso de escopo entre duas propostas do mesmo cliente é justamente o que o consultor quer
  # achar. O critério é frequência no acervo, não semelhança com um vizinho.
  test "texto copiado entre dois jobs continua recuperável" do
    a = chunk_for("25001", "5. ESCOPO", angle: IGUAIS)
    b = chunk_for("25002", "5. ESCOPO", angle: IGUAIS)

    Rag::BoilerplateDetector.new.call

    assert_not a.reload.boilerplate
    assert_not b.reload.boilerplate
  end

  test "desmarca o que deixou de se repetir quando o acervo muda" do
    repetidos = Array.new(5) { |i| chunk_for("2500#{i}", "VALIDADE", angle: IGUAIS) }
    Rag::BoilerplateDetector.new.call
    assert repetidos.first.reload.boilerplate

    repetidos.drop(1).each { |chunk| chunk.historical_proposal.destroy! }
    result = Rag::BoilerplateDetector.new.call

    assert_equal 1, result.cleared
    assert_not repetidos.first.reload.boilerplate
  end

  test "só olha a voz da Papyrus: documento do cliente não entra na conta" do
    5.times { |i| chunk_for("2500#{i}", "ANEXO", angle: IGUAIS, role: "tr_cliente") }

    result = Rag::BoilerplateDetector.new.call

    assert_equal 0, result.examined
  end

  private

  def chunk_for(job_number, section, angle:, role: "proposta_papyrus")
    proposal = HistoricalProposal.create!(
      job_name: "#{job_number}_Cliente", job_number: job_number, client_name: "Cliente",
      source_path: "/x/#{job_number}#{section}", relative_path: "#{job_number}#{section}",
      filename: "#{job_number}.docx", source_sha256: Digest::SHA256.hexdigest("#{job_number}#{section}"),
      chunker_version: Rag::Indexer::PIPELINE_VERSION, role: role, role_source: "ai", status: "ok"
    )

    embedding = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    embedding[0] = angle
    embedding[1] = Math.sqrt([ 1 - (angle**2), 0 ].max)

    proposal.chunks.create!(
      position: 0, content: section, section_title: section,
      embedding: embedding, embedded_at: Time.current, embedding_model: Rag::Embedder::MODEL_ID
    )
  end
end
