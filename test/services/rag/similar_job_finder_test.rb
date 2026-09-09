require "test_helper"

class Rag::SimilarJobFinderTest < ActiveSupport::TestCase
  # O piso do acervo entra como parâmetro nos testes porque é ele que dá sentido ao número: uma
  # similaridade de 0,70 é forte num acervo cujo piso é 0,50 e é ruído num de piso 0,75.
  PISO_BAIXO = 0.30

  test "agrupa trechos por job em vez de devolver pedaços soltos" do
    matches = find([
      hit("25001", "Petrobras", 0.90, "4. ESCOPO"),
      hit("25001", "Petrobras", 0.88, "9. EQUIPE TÉCNICA"),
      hit("25001", "Petrobras", 0.86, "3. OBJETIVOS"),
      hit("25001", "Petrobras", 0.84, "5. PRODUTOS"),
      hit("25001", "Petrobras", 0.82, "2. INTRODUÇÃO")
    ])

    assert_equal [ "25001" ], matches.map(&:job_number)
    assert_equal [ "4. ESCOPO", "9. EQUIPE TÉCNICA", "3. OBJETIVOS", "5. PRODUTOS", "2. INTRODUÇÃO" ],
      matches.first.sections
  end

  test "quem manda na cabeça do ranking vence quem tem um trecho melhor isolado" do
    hits = [ hit("25002", "Renova", 0.95, "1. APRESENTAÇÃO") ]
    hits += Array.new(9) { |i| hit("25001", "Petrobras", 0.90 - (i * 0.01), "#{i}. SEÇÃO") }

    matches = find(hits)

    assert_equal "25001", matches.first.job_number,
      "dominar a cabeça do ranking é o sinal de projeto parecido; um trecho isolado é coincidência"
  end

  # O caso da conversa 93 (BESS): a cabeça do ranking se espalhou por uma dúzia de jobs, cada um
  # com um ou dois trechos. Nenhum deles é um projeto parecido — são coincidências de parágrafo.
  test "cabeça espalhada entre muitos jobs não produz sugestão nenhuma" do
    hits = Array.new(10) { |i| hit("2500#{i}", "Cliente #{i}", 0.90 - (i * 0.01), "4. ESCOPO") }

    assert_empty find(hits), "um trecho por job em dez jobs diferentes não é semelhança"
  end

  # A frase vazia "serviços de consultoria ambiental para licenciamento" domina a cabeça do
  # ranking sem dizer nada: o piso alto do acervo é o que denuncia.
  test "domínio da cabeça não basta quando os trechos não superam o piso do acervo" do
    hits = Array.new(10) { |i| hit("25001", "Petrobras", 0.70 - (i * 0.01), "#{i}. SEÇÃO") }

    assert_empty find(hits, floor: 0.90),
      "trecho menos parecido que a média do acervo não distingue projeto nenhum"
  end

  test "distingue referência direta de aproveitável em parte" do
    forte = find(Array.new(10) { |i| hit("25001", "Petrobras", 0.95 - (i * 0.01), "#{i}. SEÇÃO") })
    assert_equal "referência direta", forte.first.confidence_label

    parcial = find(
      Array.new(5) { |i| hit("25001", "Petrobras", 0.62 - (i * 0.01), "#{i}. SEÇÃO") } +
      Array.new(5) { |i| hit("25009", "Outro", 0.56 - (i * 0.01), "#{i}. SEÇÃO") },
      floor: 0.55
    )
    assert_equal "aproveitável em parte", parcial.first.confidence_label
  end

  # Achado ao vivo (2026-09): com o acervo maior, um assunto pode ter VÁRIOS precedentes reais
  # (BESS tinha 4 jobs) — nenhum sozinho domina a cabeça do ranking, mas juntos são sinal de
  # verdade. Ver Rag::SimilarJobFinder#clustered_match?.
  test "vários jobs sem dominar a cabeça sozinhos, mas cada um com força boa, produzem sugestão (precedente múltiplo)" do
    hits = [
      hit("26098", "Newave", 0.60, "4. ESCOPO"), hit("26098", "Newave", 0.58, "3. OBJETIVOS"),
      hit("26095", "COBRA", 0.55, "4. ESCOPO"), hit("26095", "COBRA", 0.52, "3. OBJETIVOS"),
      hit("26089", "PAE", 0.50, "4. ESCOPO"), hit("26089", "PAE", 0.48, "3. OBJETIVOS"),
      hit("26063", "RioEnergy", 0.45, "4. ESCOPO"), hit("26063", "RioEnergy", 0.42, "3. OBJETIVOS")
    ]

    # limit: 4 pra provar que os QUATRO passam no filtro — MAX_JOBS (3) já trunca a exibição
    # normal, o que este teste quer verificar é o filtro em si, não o corte de exibição.
    matches = find(hits, limit: 4)

    assert_equal %w[26098 26095 26089 26063], matches.map(&:job_number)
    assert matches.all? { |m| m.strength >= 0 }, "cada job do cluster precisa ter força própria boa, não só domínio combinado"
  end

  # Mesmo domínio combinado do cluster de cima, mas com força ruim em todos — é o caso
  # "consultoria ambiental vaga" (frase genérica de domínio, sem dizer nada específico):
  # domínio combinado não basta sozinho, cada job precisa de força própria boa.
  test "vários jobs com domínio combinado mas força ruim continuam sem sugestão" do
    hits = [
      hit("A", "Cliente A", 0.28, "1. SEÇÃO"), hit("A", "Cliente A", 0.27, "2. SEÇÃO"),
      hit("B", "Cliente B", 0.26, "1. SEÇÃO"), hit("B", "Cliente B", 0.25, "2. SEÇÃO"),
      hit("C", "Cliente C", 0.24, "1. SEÇÃO"), hit("C", "Cliente C", 0.23, "2. SEÇÃO")
    ]

    assert_empty find(hits), "domínio combinado não basta sem força própria boa em pelo menos dois jobs"
  end

  test "um job só com força boa, sem outro no cluster, não basta (precisa de pelo menos dois jobs)" do
    hits = [
      hit("A", "Cliente A", 0.60, "1. SEÇÃO"), hit("A", "Cliente A", 0.58, "2. SEÇÃO"),
      hit("B", "Cliente B", 0.32, "1. SEÇÃO"),
      hit("C", "Cliente C", 0.31, "1. SEÇÃO")
    ]

    assert_empty find(hits)
  end

  test "contexto vazio não chega a consultar o acervo" do
    retriever = SpyRetriever.new([])

    assert_empty build(retriever).call("   ")
    assert_nil retriever.options
  end

  test "busca só na voz da Papyrus e sem o texto de modelo que se repete em toda proposta" do
    retriever = SpyRetriever.new([])
    build(retriever).call("monitoramento de cetáceos")

    assert_equal Rag::DocumentClassifier::VOICE_OF_PAPYRUS, retriever.options[:roles]
    assert_equal false, retriever.options[:include_boilerplate],
      "obrigações e validade são idênticas em todo job — não distinguem projeto"
  end

  test "embeda a consulta uma vez só, reaproveitando o vetor para a busca e para o piso" do
    embedder = CountingEmbedder.new
    build(SpyRetriever.new([]), embedder: embedder).call("monitoramento de cetáceos")

    assert_equal 1, embedder.calls
  end

  test "respeita o limite de jobs devolvidos" do
    hits = Array.new(5) { |i| hit("2500#{i}", "Cliente #{i}", 0.90, "4. ESCOPO") } * 2

    assert_operator find(hits, limit: 1).size, :<=, 1
  end

  private

  def find(hits, floor: PISO_BAIXO, **options)
    build(SpyRetriever.new(hits), floor: floor).call("monitoramento de cetáceos", **options)
  end

  def build(retriever, floor: PISO_BAIXO, embedder: CountingEmbedder.new)
    Rag::SimilarJobFinder.new(
      retriever: retriever, embedder: embedder, floor: FixedFloor.new(floor)
    )
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

    def hits_for(_vector, **options)
      @options = options
      @hits
    end
  end

  class CountingEmbedder
    attr_reader :calls

    def initialize = @calls = 0

    def embed_query(_text)
      @calls += 1
      [ 1.0 ]
    end
  end

  FixedFloor = Struct.new(:similarity) do
    def call(_vector) = Rag::CorpusFloor::Floor.new(similarity: similarity)
  end
end
