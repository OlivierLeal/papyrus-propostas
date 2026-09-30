require "test_helper"

# O plano da IA só aponta (fato → célula, peça → item); todo número sai do Ruby (CLAUDE.md seção 1).
class Spreadsheets::PlanExecutorTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @proposal.project_pricing.recalculate!
    @catalog = Spreadsheets::FactCatalog.new(@proposal)
    @pieces = @catalog.pieces.map(&:key)
    @total = @catalog["proposta.total"].value.round(2)
  end

  test "o catálogo cobre o preço inteiro: peças × BDI e impostos = total da proposta" do
    assert @pieces.any?
    sum = @catalog.pieces.sum { |piece| piece.value * @catalog.piece_multiplier(piece.key) }
    assert_in_delta @total.to_f, sum.to_f, 0.05
  end

  test "preço unitário rateado fecha com o total da proposta e o rótulo recebe o dado" do
    first, *rest = @pieces
    plan = {
      "celulas" => [ { "aba" => "PPU", "celula" => "A1", "fato" => "papyrus.razao_social" } ],
      "precos_unitarios" => [
        { "aba" => "PPU", "celula" => "F3", "quantidade_celula" => "E3",
          "composicao" => [ { "peca" => first, "fracao" => 0.5 } ] + rest.map { |key| { "peca" => key, "fracao" => 1 } } },
        { "aba" => "PPU", "celula" => "F4", "quantidade_celula" => "E4", "composicao" => [ { "peca" => first, "fracao" => 0.5 } ] }
      ]
    }
    result = run_plan(plan)
    workbook = Spreadsheets::Workbook.open(result.bytes)

    sheet_total = 100 * workbook.value("PPU", "F3").to_d + 3 * workbook.value("PPU", "F4").to_d
    assert_equal @total, sheet_total.round(2)
    assert_equal "LICITANTE: PAPYRUS CONSULTORIA AMBIENTAL LTDA", workbook.value("PPU", "A1")
    assert_empty result.issues
  end

  test "frações que não fecham 100% são ajustadas mantendo a proporção, com aviso" do
    plan = { "precos_unitarios" => [
      { "aba" => "PPU", "celula" => "F3", "quantidade_celula" => "E3", "composicao" => @pieces.map { |key| { "peca" => key, "fracao" => 0.6 } } },
      { "aba" => "PPU", "celula" => "F4", "quantidade_celula" => "E4", "composicao" => @pieces.map { |key| { "peca" => key, "fracao" => 0.3 } } }
    ] }
    result = run_plan(plan)

    assert_equal @total, result.totals[:planilha].to_d.round(2)
    assert result.warnings.any? { |w| w.include?("somava 90%") }
  end

  test "peça que ficou de fora vira pendência e a diferença não é escondida em outro item" do
    skip "fixture com uma peça só" if @pieces.size < 2
    plan = { "precos_unitarios" => [
      { "aba" => "PPU", "celula" => "F3", "quantidade_celula" => "E3", "composicao" => [ { "peca" => @pieces.first, "fracao" => 1 } ] }
    ] }
    result = run_plan(plan)

    assert result.issues.any? { |text| text.start_with?("Custo que não entrou na planilha") }
    assert result.totals[:planilha] < result.totals[:proposta]
  end

  test "IA não escreve número: texto numérico é recusado, fato não informado vira pendência" do
    plan = { "celulas" => [
      { "aba" => "PPU", "celula" => "F3", "texto" => "R$ 1.234,00" },
      { "aba" => "PPU", "celula" => "B1", "fato" => "papyrus.sindicato" },
      { "aba" => "PPU", "celula" => "B2", "fato" => "inventado.pela.ia" }
    ], "faltando" => [ "Benefício fiscal no estado" ], "duvidas" => [ "As diárias batem?" ] }
    stub_company("sindicato" => nil) do
      result = run_plan(plan)

      assert_nil Spreadsheets::Workbook.open(result.bytes).value("PPU", "F3")
      assert result.warnings.any? { |w| w.include?("texto numérico recusado") }
      assert result.warnings.any? { |w| w.include?("inventado.pela.ia") }
      assert result.issues.any? { |text| text.include?("Sindicato") }
      assert_includes result.issues, "Falta informar: Benefício fiscal no estado"
      assert_equal [ "As diárias batem?" ], result.doubts
    end
  end

  test "dado que falta aparece uma vez: BDI numa linha só e o 'faltando' da IA não repete o catálogo" do
    stub_company("sindicato" => nil, "bdi_componentes" => {}) do
      plan = { "celulas" => [
        { "aba" => "PPU", "celula" => "B1", "fato" => "papyrus.sindicato" },
        { "aba" => "PPU", "celula" => "B2", "fato" => "bdi.lucro" },
        { "aba" => "PPU", "celula" => "B3", "fato" => "bdi.riscos" }
      ], "faltando" => [ "Sindicato considerado na proposta (DADOS GERAIS!B29) — NÃO INFORMADO no catálogo",
                        "Margem de lucro / bdi.lucro (BDI!A3)", "Benefício fiscal no estado (B34)" ] }
      result = run_plan(plan)

      assert_equal 1, result.issues.count { |text| text.include?("Sindicato") }
      assert_equal 1, result.issues.count { |text| text.include?("bdi.") }
      assert_includes result.issues, "Falta informar: Benefício fiscal no estado (B34)"
      assert_equal %w[papyrus.sindicato bdi.lucro bdi.riscos], result.missing_keys
    end
  end

  test "tabela de equipe: uma linha por profissional, em aba oculta mostrada" do
    line = @pieces.find { |key| key.start_with?("L") }
    plan = { "abas_mostrar" => [ "Equipe" ], "tabelas" => [
      { "aba" => "Equipe", "linha_modelo" => 2, "linhas" => [ { "A" => { "fato" => "#{line}.profissional" }, "B" => { "fato" => "#{line}.hh" } } ] }
    ] }
    result = run_plan(plan)
    workbook = Spreadsheets::Workbook.open(result.bytes)

    assert_equal @catalog["#{line}.profissional"].value, workbook.value("Equipe", "A2")
    assert_equal "visible", workbook.sheet("Equipe").state
  end

  test "administração central fecha o BDI da planilha com BDI × impostos da proposta" do
    stub_company("bdi_componentes" => { "lucro" => 0.08, "riscos" => 0.01, "seguros_garantias" => 0.008, "despesas_financeiras" => 0.01 }) do
      catalog = Spreadsheets::FactCatalog.new(@proposal)
      adm, riscos, seguros, fin, lucro = %w[administracao_central riscos seguros_garantias despesas_financeiras lucro].map { |k| catalog["bdi.#{k}"].value }
      taxes = %w[iss pis cofins cprb outros].sum { |k| catalog["tributo.#{k}"].value.to_d }
      # Fórmula da DFP (Petrobras): custo × (1 + adm + riscos + seguros) × (1 + fin) × (1 + lucro) ÷ (1 − tributos)
      price_factor = (1 + adm + riscos + seguros) * (1 + fin) * (1 + lucro) / (1 - taxes)

      assert_in_delta @proposal.project_pricing.multiplier.to_f, price_factor.to_f, 0.00001
    end
  end

  private

  def run_plan(plan)
    Spreadsheets::PlanExecutor.new(Spreadsheets::Workbook.open(client_xlsx_bytes), @catalog, plan).call
  end

  def stub_company(overrides)
    original = PapyrusCompany.method(:data)
    PapyrusCompany.define_singleton_method(:data) { original.call.merge(overrides) }
    @catalog = Spreadsheets::FactCatalog.new(@proposal)
    yield
  ensure
    PapyrusCompany.define_singleton_method(:data, original)
  end
end
