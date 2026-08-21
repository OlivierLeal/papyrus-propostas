require "test_helper"

class Rag::SimilarJobFinderTest < ActiveSupport::TestCase
  test "agrupa trechos por job em vez de devolver pedaços soltos" do
    hits = [
      hit("25001", "Petrobras", 0.78, "4. ESCOPO"),
      hit("25001", "Petrobras", 0.74, "9. EQUIPE TÉCNICA"),
      hit("25001", "Petrobras", 0.71, "3. OBJETIVOS"),
      hit("25002", "Renova", 0.70, "1. APRESENTAÇÃO"),
      hit("25002", "Renova", 0.68, "6. OBRIGAÇÕES"),
      hit("25002", "Renova", 0.66, "10. PRAZO")
    ]

    matches = find(hits)

    assert_equal %w[25001 25002], matches.map(&:job_number)
    assert_equal [ "4. ESCOPO", "9. EQUIPE TÉCNICA", "3. OBJETIVOS" ], matches.first.sections
  end

  test "job que casa em várias seções pontua acima de um que casou uma vez por acaso" do
    hits = [
      hit("25002", "Renova", 0.80, "1. APRESENTAÇÃO"),
      hit("25001", "Petrobras", 0.79, "4. ESCOPO"),
      hit("25001", "Petrobras", 0.78, "9. EQUIPE"),
      hit("25001", "Petrobras", 0.77, "3. OBJETIVOS")
    ]

    matches = find(hits)

    assert_equal "25001", matches.first.job_number,
      "três seções fortes valem mais que um único trecho ligeiramente melhor"
  end

  test "descarta job abaixo do limiar de semelhança" do
    assert_empty find([ hit("25001", "Petrobras", 0.40, "1. APRESENTAÇÃO") ])
  end

  test "um único trecho parecido não faz um projeto semelhante" do
    # Mesmo com similaridade alta, um job que casou em UMA seção não serve de modelo para
    # escrever uma proposta inteira — é coincidência de parágrafo, não de projeto.
    assert_empty find([ hit("25001", "Petrobras", 0.80, "1. APRESENTAÇÃO") ])
  end

  test "contexto vazio não chega a consultar o acervo" do
    retriever = SpyRetriever.new([])

    assert_empty Rag::SimilarJobFinder.new(retriever: retriever).call("   ")
    assert_nil retriever.options
  end

  test "busca só na voz da Papyrus: o objetivo é achar proposta modelo, não TR de cliente" do
    retriever = SpyRetriever.new([])
    Rag::SimilarJobFinder.new(retriever: retriever).call("monitoramento de cetáceos")

    assert_equal Rag::DocumentClassifier::VOICE_OF_PAPYRUS, retriever.options[:roles]
  end

  test "respeita o limite de jobs devolvidos" do
    hits = (1..5).flat_map do |i|
      [ hit("2500#{i}", "Cliente #{i}", 0.80, "4. ESCOPO"),
        hit("2500#{i}", "Cliente #{i}", 0.78, "9. EQUIPE"),
        hit("2500#{i}", "Cliente #{i}", 0.76, "3. OBJETIVOS") ]
    end

    assert_equal 2, find(hits, limit: 2).size
  end

  private

  def find(hits, **options)
    Rag::SimilarJobFinder.new(retriever: SpyRetriever.new(hits)).call("monitoramento de cetáceos", **options)
  end

  def hit(job_number, client, similarity, section)
    proposal = HistoricalProposal.new(
      job_number: job_number, client_name: client, subject: "Assunto", year: 2025,
      filename: "#{job_number}.docx", job_name: "#{job_number}_#{client}", role: "proposta_papyrus",
      source_path: "/x", relative_path: "x", source_sha256: "a" * 64, chunker_version: "1",
      role_source: "ai", status: "ok"
    )
    number, title = section.split(". ", 2)
    chunk = HistoricalProposalChunk.new(
      content: "Trecho", section_number: number, section_title: title, historical_proposal: proposal
    )

    Rag::Retriever::Hit.new(chunk: chunk, distance: (1 - similarity).round(4))
  end

  class SpyRetriever
    attr_reader :options

    def initialize(hits) = @hits = hits

    def call(_query, **options)
      @options = options
      @hits
    end
  end
end
