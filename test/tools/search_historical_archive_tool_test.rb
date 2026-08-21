require "test_helper"

class SearchHistoricalArchiveToolTest < ActiveSupport::TestCase
  test "busca na voz da Papyrus por padrão" do
    retriever = SpyRetriever.new([ hit("5. OBRIGAÇÕES DA PAPYRUS\n\nExecutar as atividades.") ])

    result = call(retriever, busca: "obrigações da contratante")

    assert_equal Rag::DocumentClassifier::VOICE_OF_PAPYRUS, retriever.options[:roles]
    assert_equal 1, result["resultados"].size
  end

  test "fonte cliente busca nos documentos recebidos, não nos escritos pela Papyrus" do
    retriever = SpyRetriever.new([])

    call(retriever, busca: "exigências de biópsia", fonte: "cliente")

    assert_includes retriever.options[:roles], "tr_cliente"
    assert_includes retriever.options[:roles], "anexo_tecnico"
    assert_not_includes retriever.options[:roles], "proposta_papyrus"
  end

  test "fonte tudo remove a restrição de papel" do
    retriever = SpyRetriever.new([])

    call(retriever, busca: "qualquer coisa", fonte: "tudo")

    assert_nil retriever.options[:roles]
  end

  test "fonte desconhecida cai na voz da Papyrus em vez de buscar em tudo" do
    retriever = SpyRetriever.new([])

    call(retriever, busca: "algo", fonte: "inventada")

    assert_equal Rag::DocumentClassifier::VOICE_OF_PAPYRUS, retriever.options[:roles]
  end

  test "repassa o filtro de cliente" do
    retriever = SpyRetriever.new([])

    call(retriever, busca: "cetáceos", cliente: "Petrobras")

    assert_equal "Petrobras", retriever.options[:client_name]
  end

  test "cada trecho vem com a origem para a IA poder citar a fonte" do
    result = call(SpyRetriever.new([ hit("Trecho do escopo") ]), busca: "escopo")
    origem = result["resultados"].first["origem"]

    assert_equal "Petrobras", origem["cliente"]
    assert_equal "proposta.docx", origem["documento"]
    assert_equal "4. ESCOPO", origem["secao"]
    assert_equal "proposta_papyrus", origem["tipo"]
  end

  test "cada trecho traz a citação pronta, para a IA não ter desculpa de omitir a fonte" do
    result = call(SpyRetriever.new([ hit("Trecho do escopo") ]), busca: "escopo")
    primeiro = result["resultados"].first

    assert_equal "acervo Papyrus: projeto 25001 — Petrobras (4. ESCOPO, 2025)", primeiro["referencia"]
    assert result["instrucao"].present?, "o retorno lembra a IA de citar"
  end

  test "acervo sem resultado devolve aviso, não erro" do
    result = call(SpyRetriever.new([]), busca: "mineração de lítio")

    assert_empty result["resultados"]
    assert result["aviso"].present?
    assert_nil result["error"]
  end

  test "busca vazia é recusada sem chamar o retriever" do
    retriever = SpyRetriever.new([])

    result = call(retriever, busca: "   ")

    assert result["error"].present?
    assert_nil retriever.options
  end

  test "falha do retriever não derruba a conversa" do
    result = call(BrokenRetriever.new, busca: "escopo")

    assert result["error"].present?
  end

  private

  def call(retriever, **args)
    JSON.parse(SearchHistoricalArchiveTool.new(retriever: retriever).execute(**args))
  end

  def hit(content)
    proposal = HistoricalProposal.new(
      client_name: "Petrobras", filename: "proposta.docx", job_number: "25001", year: 2025,
      role: "proposta_papyrus", job_name: "25001_Petrobras", source_path: "/x", relative_path: "x",
      source_sha256: "a" * 64, chunker_version: "1", role_source: "ai", status: "ok"
    )
    chunk = HistoricalProposalChunk.new(
      content: content, section_number: "4", section_title: "ESCOPO", historical_proposal: proposal
    )

    Rag::Retriever::Hit.new(chunk: chunk, distance: 0.23)
  end

  class SpyRetriever
    attr_reader :options

    def initialize(hits) = @hits = hits

    def call(_query, **options)
      @options = options
      @hits
    end
  end

  class BrokenRetriever
    def call(_query, **_options) = raise(Rag::Embedder::Error, "Bedrock indisponível")
  end
end
