require "test_helper"

class SearchLegalNormsToolTest < ActiveSupport::TestCase
  class FakeNormas
    attr_reader :calls, :find_calls

    def initialize(result: nil, by_codigo: {})
      @result = result
      @by_codigo = by_codigo
      @calls = []
      @find_calls = []
    end

    def search(**args)
      @calls << args
      @result
    end

    def find_by_codigo(codigo)
      @find_calls << codigo
      @by_codigo[codigo]
    end
  end

  class FakeDocumento
    attr_reader :calls

    def initialize(texts: {})
      @texts = texts
      @calls = []
    end

    def fetch(anexo_id)
      @calls << anexo_id
      text = @texts[anexo_id]
      return nil if text.nil?

      Cal::Documento::Result.new(pdf_bytes: "bytes-fake-#{anexo_id}", content_type: "application/pdf", text: text, ocr_used: false)
    end
  end

  class RaisingNormas
    def initialize(error)
      @error = error
    end

    def search(**)
      raise @error
    end

    def find_by_codigo(*)
      raise @error
    end
  end

  def norma(codigo: "NL1", orgao: "INEMA", anexo_id: nil)
    Cal::Norma.from_api(
      "Codigo" => codigo, "TipoNormaENumeroEAnoPromulgacao" => "Portaria 1/20", "OrgaoNome" => orgao,
      "AmbitoNome" => "Estadual", "Assunto" => "Sobre alguma coisa", "DataPromulgacao" => "/Date(1577836800000)/",
      "NormaAplicavelCliente" => true, "NomeAnexo" => anexo_id
    )
  end

  test "requires a palavra_chave or a codigo_norma" do
    tool = SearchLegalNormsTool.new(normas: FakeNormas.new)

    result = JSON.parse(tool.execute(palavra_chave: "  "))

    assert_includes result["error"], "Preciso saber o que buscar no CAL"
  end

  test "returns the normas found, each with a ready-to-cite referencia" do
    fake = FakeNormas.new(result: Cal::Normas::Result.new(normas: [ norma ], pagina_atual: 1, total_paginas: 1, total_itens: 1))
    tool = SearchLegalNormsTool.new(normas: fake)

    result = JSON.parse(tool.execute(palavra_chave: "licenciamento"))

    assert_equal 1, result["total_encontrado"]
    assert_equal "NL1", result["resultados"].first["codigo"]
    assert_includes result["resultados"].first["referencia"], "CAL/Ius Natura"
    assert_equal "licenciamento", fake.calls.sole[:palavra_chave]
  end

  test "returns an empty-result notice when nothing is found, instead of an error" do
    fake = FakeNormas.new(result: Cal::Normas::Result.new(normas: [], pagina_atual: 1, total_paginas: 0, total_itens: 0))
    tool = SearchLegalNormsTool.new(normas: fake)

    result = JSON.parse(tool.execute(palavra_chave: "algo bem específico"))

    assert_equal [], result["resultados"]
    assert result["aviso"].present?
  end

  test "returns a friendly error instead of raising when the CAL authentication fails" do
    tool = SearchLegalNormsTool.new(normas: RaisingNormas.new(Cal::Client::AuthenticationError.new("sessão morta")))

    result = JSON.parse(tool.execute(palavra_chave: "fauna"))

    assert result["error"].present?
  end

  test "returns a friendly error instead of raising on any other failure" do
    tool = SearchLegalNormsTool.new(normas: RaisingNormas.new(StandardError.new("timeout")))

    result = JSON.parse(tool.execute(palavra_chave: "fauna"))

    assert result["error"].present?
  end

  test "caps results at LIMIT even when the CAL returns more" do
    normas = Array.new(SearchLegalNormsTool::LIMIT + 5) { |i| norma(codigo: "NL#{i}") }
    fake = FakeNormas.new(result: Cal::Normas::Result.new(normas: normas, pagina_atual: 1, total_paginas: 1, total_itens: normas.size))
    tool = SearchLegalNormsTool.new(normas: fake)

    result = JSON.parse(tool.execute(palavra_chave: "muitas normas"))

    assert_equal SearchLegalNormsTool::LIMIT, result["resultados"].size
    assert_equal normas.size, result["total_encontrado"] # o total real fica visível mesmo cortando a lista
  end

  # TEXTO COMPLETO (codigo_norma) — a busca só devolve o resumo (Assunto); pra afirmar o que a
  # norma exige de verdade, a IA precisa pedir o documento inteiro.
  test "codigo_norma ignores palavra_chave and returns the full document text instead of a list" do
    achada = norma(codigo: "NL7484", anexo_id: "guid-1")
    normas = FakeNormas.new(by_codigo: { "NL7484" => achada })
    documento = FakeDocumento.new(texts: { "guid-1" => "texto completo da portaria..." })
    tool = SearchLegalNormsTool.new(normas: normas, documento: documento)

    result = stub_embedder { JSON.parse(tool.execute(palavra_chave: "isso deve ser ignorado", codigo_norma: "NL7484")) }

    assert_equal "texto completo da portaria...", result["texto"]
    assert_includes result["referencia"], "NL7484"
    assert_empty normas.calls # nunca chamou #search
    assert_equal [ "NL7484" ], normas.find_calls
    assert_equal [ "guid-1" ], documento.calls
  end

  test "codigo_norma returns a friendly error when the code isn't found" do
    normas = FakeNormas.new(by_codigo: {})
    tool = SearchLegalNormsTool.new(normas: normas, documento: FakeDocumento.new)

    result = JSON.parse(tool.execute(codigo_norma: "NL0"))

    assert_includes result["error"], "NL0"
  end

  test "codigo_norma still returns the referencia when the document text can't be read" do
    achada = norma(codigo: "NL7484", anexo_id: "guid-1")
    normas = FakeNormas.new(by_codigo: { "NL7484" => achada })
    documento = FakeDocumento.new(texts: {}) # simula PDF escaneado / não encontrado
    tool = SearchLegalNormsTool.new(normas: normas, documento: documento)

    result = JSON.parse(tool.execute(codigo_norma: "NL7484"))

    assert_nil result["texto"]
    assert_includes result["referencia"], "NL7484"
    assert result["aviso"].present?
  end

  test "codigo_norma returns a friendly error instead of raising on failure" do
    tool = SearchLegalNormsTool.new(normas: RaisingNormas.new(StandardError.new("timeout")), documento: FakeDocumento.new)

    result = JSON.parse(tool.execute(codigo_norma: "NL1"))

    assert result["error"].present?
  end

  # Cache-first (2026-09, CLAUDE.md seção 11.2) — ver Rag::LegalNormIndexerTest/DocumentoTest pro
  # detalhe da persistência em si; aqui só o comportamento da ferramenta.
  test "codigo_norma persists a LegalNorm (with the PDF and embedded chunks) on the first fetch" do
    achada = norma(codigo: "NL7484", anexo_id: "guid-1")
    normas = FakeNormas.new(by_codigo: { "NL7484" => achada })
    documento = FakeDocumento.new(texts: { "guid-1" => "texto completo da portaria... #{'artigo de teste. ' * 20}" })
    tool = SearchLegalNormsTool.new(normas: normas, documento: documento)

    assert_difference "LegalNorm.count", 1 do
      stub_embedder { tool.execute(codigo_norma: "NL7484") }
    end

    legal_norm = LegalNorm.find_by(codigo: "NL7484")
    assert legal_norm.pdf.attached?
    assert legal_norm.chunks.any?
    assert legal_norm.chunks.all? { |chunk| chunk.embedding.present? }
  end

  test "codigo_norma does not persist anything when the document text can't be read" do
    achada = norma(codigo: "NL7484", anexo_id: "guid-1")
    normas = FakeNormas.new(by_codigo: { "NL7484" => achada })
    documento = FakeDocumento.new(texts: {})
    tool = SearchLegalNormsTool.new(normas: normas, documento: documento)

    assert_no_difference "LegalNorm.count" do
      tool.execute(codigo_norma: "NL7484")
    end
  end

  # Segunda chamada com o MESMO código: nunca mais bate no CAL — nem busca (#search/#find_by_codigo),
  # nem download (#fetch) — só lê o que já está guardado.
  test "codigo_norma answers from the local cache on a second call, without touching normas or documento at all" do
    achada = norma(codigo: "NL7484", anexo_id: "guid-1")
    normas = FakeNormas.new(by_codigo: { "NL7484" => achada })
    documento = FakeDocumento.new(texts: { "guid-1" => "texto completo da portaria... #{'artigo de teste. ' * 20}" })
    tool = SearchLegalNormsTool.new(normas: normas, documento: documento)
    stub_embedder { tool.execute(codigo_norma: "NL7484") }

    # Ferramenta NOVA, sem nenhum normas/documento passado — se ela precisasse do CAL de novo,
    # quebraria (Cal::Normas.new/Cal::Documento.new tentariam falar com o CAL de verdade).
    cached_tool = SearchLegalNormsTool.new
    result = JSON.parse(cached_tool.execute(codigo_norma: "NL7484"))

    assert_includes result["texto"], "texto completo da portaria"
    assert_includes result["referencia"], "NL7484"
  end
end
