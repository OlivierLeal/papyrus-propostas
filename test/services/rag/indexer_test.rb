require "test_helper"

class Rag::IndexerTest < ActiveSupport::TestCase
  test "grava documento, chunks e embeddings" do
    result = Rag::Indexer.new(embedder: FakeEmbedder.new).call([ job_with(chunks: 2) ])

    assert_equal 1, result.indexed
    assert_equal 2, result.chunks
    assert_equal 2, result.embedded

    record = HistoricalProposal.sole
    assert_equal "proposta_papyrus", record.role
    assert_equal "25001", record.job_number
    assert_equal Rag::Indexer::PIPELINE_VERSION, record.chunker_version
    assert_equal 2, record.chunks.count
    assert record.chunks.all? { |chunk| chunk.embedding.present? }
  end

  test "reindexar o mesmo acervo não duplica nem re-embeda" do
    embedder = FakeEmbedder.new
    job = job_with(chunks: 3)

    Rag::Indexer.new(embedder: embedder).call([ job ])
    result = Rag::Indexer.new(embedder: embedder).call([ job ])

    assert_equal 1, result.skipped
    assert_equal 0, result.indexed
    assert_equal 3, embedder.calls, "a segunda passada não pode gerar embedding de novo"
    assert_equal 3, HistoricalProposalChunk.count
  end

  test "conteúdo alterado substitui os chunks antigos" do
    embedder = FakeEmbedder.new
    Rag::Indexer.new(embedder: embedder).call([ job_with(chunks: 3) ])
    Rag::Indexer.new(embedder: embedder).call([ job_with(chunks: 1, sha256: "b" * 64) ])

    assert_equal 2, HistoricalProposal.count
    assert_equal 4, HistoricalProposalChunk.count
  end

  test "falha ao embedar preserva os chunks para a próxima execução" do
    result = Rag::Indexer.new(embedder: BrokenEmbedder.new).call([ job_with(chunks: 2) ])

    assert_equal 1, result.indexed
    assert_equal 0, result.embedded
    assert_equal 2, HistoricalProposalChunk.pending_embedding.count, "chunk fica pendente, não some"
  end

  test "--no-embed grava sem gastar chamada de embedding" do
    embedder = FakeEmbedder.new
    Rag::Indexer.new(embed: false, embedder: embedder).call([ job_with(chunks: 2) ])

    assert_equal 0, embedder.calls
    assert_equal 2, HistoricalProposalChunk.pending_embedding.count
  end

  private

  def job_with(chunks:, sha256: "a" * 64, role: "proposta_papyrus")
    item = Rag::Inventory::Item.new(
      path: "/acervo/25001_Petrobras/proposta.docx", filename: "proposta.docx",
      relative_path: "25001_Petrobras/proposta.docx", sha256: sha256, byte_size: 10,
      extension: "docx", numero_proposta: "25001", revision: 0, year: 2025,
      superseded: false, spreadsheet_path: nil
    )

    document = Rag::Ingestion::Document.new(
      item: item, status: :ok, role: role, role_source: :ai, page_count: 3, chars_per_page: 900,
      chunks: Array.new(chunks) { |i| chunk(i) }, pricing_sheet_rows: 0, error: nil
    )

    Rag::Ingestion::Job.new(name: "25001_Petrobras_Cetaceos", numero: "25001",
                            client_name: "Petrobras", subject: "Cetaceos", documents: [ document ])
  end

  def chunk(position)
    Rag::Ingestion::Chunk.new(
      position: position, section_number: "4", section_title: "ESCOPO",
      content: "Trecho #{position} do escopo dos serviços ambientais.", char_count: 50,
      estimated_tokens: 13, sensitive: false, contains_pricing: false, sensitivity_reasons: []
    )
  end

  class FakeEmbedder
    attr_reader :calls

    def initialize = @calls = 0

    def embed_documents(texts)
      @calls += texts.size
      texts.map { Array.new(Rag::Embedder::DIMENSIONS) { 0.01 } }
    end
  end

  class BrokenEmbedder
    def embed_documents(_texts) = raise(Rag::Embedder::Error, "Bedrock 500")
  end
end
