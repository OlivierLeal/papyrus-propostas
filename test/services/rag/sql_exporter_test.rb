require "test_helper"

class Rag::SqlExporterTest < ActiveSupport::TestCase
  # O SQL exportado traz BEGIN/COMMIT de verdade — executá-lo dentro da transação de teste do
  # Rails confirmaria tudo e vazaria dados para os testes seguintes. Rodar sem transação e
  # limpar à mão testa o arquivo exatamente como ele será usado no destino.
  self.use_transactional_tests = false

  setup do
    limpar
    @proposal = create_proposal(sha: "a" * 64, job: "25001", client: "Petrobras")
    @chunk = @proposal.chunks.create!(
      position: 0, section_number: "4", section_title: "ESCOPO",
      content: "Trecho com 'aspas' e \\barra invertida.", token_count: 12,
      sensitive: true, contains_pricing: false, sensitivity_reasons: %w[money cnpj],
      embedding: Array.new(Rag::Embedder::DIMENSIONS) { 0.0123456789 },
      embedding_model: Rag::Embedder::MODEL_ID, embedded_at: Time.current
    )
  end

  test "o SQL gerado carrega de verdade num banco limpo" do
    sql = export
    limpar
    execute(sql)

    proposal = HistoricalProposal.sole
    assert_equal "25001", proposal.job_number
    assert_equal "Petrobras", proposal.client_name
    assert_equal "a" * 64, proposal.source_sha256

    chunk = proposal.chunks.sole
    assert_equal @chunk.content, chunk.content, "conteúdo com aspas e barra precisa sobreviver"
    assert_equal %w[money cnpj], chunk.sensitivity_reasons
    assert chunk.sensitive
    assert_equal Rag::Embedder::DIMENSIONS, chunk.embedding.size
  end

  test "carregar duas vezes não duplica nada" do
    sql = export

    2.times { execute(sql) }

    assert_equal 1, HistoricalProposal.where(source_sha256: "a" * 64).count
    assert_equal 1, HistoricalProposalChunk.count
  end

  test "recarregar substitui os trechos em vez de somar" do
    sql = export  # exportado quando o documento tinha 1 trecho
    execute(sql)

    # O destino ganhou um trecho a mais (versão anterior do mesmo documento, por exemplo).
    @proposal.chunks.create!(position: 1, content: "trecho de uma versão anterior")
    assert_equal 2, HistoricalProposalChunk.count

    execute(sql)

    assert_equal 1, HistoricalProposalChunk.count, "o trecho antigo não pode ficar para trás"
  end

  test "o vetor sobrevive à exportação com precisão suficiente para a busca" do
    execute(export)

    exportado = HistoricalProposalChunk.sole.embedding
    assert_in_delta 0.0123456789, exportado.first, 10**-Rag::SqlExporter::VECTOR_PRECISION
  end

  test "trecho sem embedding é exportado como NULL, não quebra o carregamento" do
    @chunk.update_columns(embedding: nil, embedded_at: nil)

    execute(export)

    assert_nil HistoricalProposalChunk.sole.embedding
  end

  test "o escopo limita o que é exportado" do
    create_proposal(sha: "b" * 64, job: "25002", client: "Renova")

    sql = Rag::SqlExporter.new(scope: HistoricalProposal.where(job_number: "25001")).then do |exporter|
      StringIO.new.tap { |io| exporter.call(io) }.string
    end

    assert_includes sql, "Petrobras"
    assert_not_includes sql, "Renova"
  end

  teardown { limpar }

  private

  def limpar
    HistoricalProposalChunk.delete_all
    HistoricalProposal.delete_all
  end

  def export
    StringIO.new.tap { |io| Rag::SqlExporter.new.call(io) }.string
  end

  # O SQL é feito para o psql, que aceita várias instruções por envio; o adapter faz o mesmo.
  def execute(sql)
    HistoricalProposal.connection.execute(sql)
  end

  def create_proposal(sha:, job:, client:)
    HistoricalProposal.create!(
      job_name: "#{job}_#{client}", job_number: job, client_name: client, subject: "Assunto",
      source_path: "/acervo/#{job}/proposta.docx", relative_path: "#{job}/proposta.docx",
      filename: "proposta.docx", source_sha256: sha, chunker_version: Rag::Indexer::PIPELINE_VERSION,
      role: "proposta_papyrus", role_source: "ai", status: "ok", page_count: 3, year: 2025
    )
  end
end
