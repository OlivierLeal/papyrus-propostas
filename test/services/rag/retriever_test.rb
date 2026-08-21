require "test_helper"

class Rag::RetrieverTest < ActiveSupport::TestCase
  setup do
    @proposta = chunk_for("proposta_papyrus", "escopo dos serviços ambientais", vector: 1.0)
    @tr = chunk_for("tr_cliente", "exigências do termo de referência", vector: 0.9)
    @sensivel = chunk_for("proposta_papyrus", "CRBio: 36.780/08-D", vector: 0.95, sensitive: true)
  end

  test "por padrão busca só na voz da Papyrus" do
    hits = retrieve("escopo")

    assert_includes hits.map { |hit| hit.chunk.id }, @proposta.id
    assert_not_includes hits.map { |hit| hit.chunk.id }, @tr.id, "texto do cliente não é voz da Papyrus"
  end

  test "aceita restringir a outro papel" do
    hits = retrieve("escopo", roles: [ "tr_cliente" ])

    assert_equal [ @tr.id ], hits.map { |hit| hit.chunk.id }
  end

  test "trecho com dado identificável fica fora por padrão" do
    assert_not_includes retrieve("escopo").map { |hit| hit.chunk.id }, @sensivel.id
    assert_includes retrieve("escopo", include_sensitive: true).map { |hit| hit.chunk.id }, @sensivel.id
  end

  test "revisão superseded não é recuperada" do
    @proposta.historical_proposal.update!(superseded: true)

    assert_empty retrieve("escopo")
  end

  test "chunk sem embedding não é recuperado" do
    @proposta.update!(embedded_at: nil)

    assert_empty retrieve("escopo")
  end

  test "descarta resultado acima do limiar de distância" do
    # Vetor ortogonal ao dos chunks: distância cosseno vai a 1, acima do MAX_DISTANCE.
    far = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    far[-1] = 1.0

    assert_empty Rag::Retriever.new(embedder: FixedEmbedder.new(far)).call("nada a ver")
  end

  private

  def retrieve(query, **options)
    vector = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    vector[0] = 1.0
    Rag::Retriever.new(embedder: FixedEmbedder.new(vector)).call(query, **options)
  end

  # Vetores esparsos: só a primeira posição varia, então a similaridade é previsível no teste.
  def chunk_for(role, content, vector:, sensitive: false)
    proposal = HistoricalProposal.create!(
      job_name: "25001_Cliente_Assunto", job_number: "25001", client_name: "Petrobras",
      source_path: "/x/#{content}", relative_path: content, filename: "#{content}.docx",
      source_sha256: Digest::SHA256.hexdigest(content), chunker_version: Rag::Indexer::PIPELINE_VERSION,
      role: role, role_source: "ai", status: "ok"
    )

    embedding = Array.new(Rag::Embedder::DIMENSIONS) { 0.0 }
    embedding[0] = vector
    embedding[1] = Math.sqrt([ 1 - (vector**2), 0 ].max)

    proposal.chunks.create!(
      position: 0, content: content, sensitive: sensitive,
      embedding: embedding, embedded_at: Time.current, embedding_model: Rag::Embedder::MODEL_ID
    )
  end

  FixedEmbedder = Struct.new(:vector) do
    def embed_query(_text) = vector
  end
end
