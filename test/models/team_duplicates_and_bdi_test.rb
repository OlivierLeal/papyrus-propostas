require "test_helper"

# 2026-09-30 (consultor): a mesma pessoa aparecia repetida na equipe, e a Diretoria (Charlene,
# Ricardo, Sara) não cobra HH/diária — o custo dela já está no BDI.
class TeamDuplicatesAndBdiTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @item = pricing_items(:servico_item)
    @biologa = professionals(:biologa)
  end

  test "a mesma pessoa duas vezes no mesmo item vira uma linha só, com o esforço somado" do
    lines = [
      { "professional_id" => @biologa.id, "deliverable_name" => "Relatório de avifauna", "man_hours" => 20, "field_days" => 2 },
      { "professional_id" => @biologa.id, "deliverable_name" => "Relatório de mastofauna", "man_hours" => 10, "field_days" => 0 }
    ]

    assert_no_difference -> { @pricing.proposal_professionals.count } do
      @proposal.send(:apply_team_lines!, @pricing, lines, @item)
    end

    line = @pricing.proposal_professionals.find_by(professional: @biologa)
    assert_equal 60, line.man_hours # 30 da fixture + 20 + 10
    assert_equal 50, line.field_days
    assert_equal "Diagnóstico de fauna e flora; Relatório de avifauna; Relatório de mastofauna", line.deliverable_name
  end

  test "em outro item a pessoa ganha outra linha (trabalho diferente)" do
    other = @pricing.pricing_items.create!(name: "Relatório final", position: 9)
    lines = [ { "professional_id" => @biologa.id, "deliverable_name" => "Relatório final", "man_hours" => 10, "field_days" => 0 } ]

    assert_difference -> { @pricing.proposal_professionals.count }, 1 do
      @proposal.send(:apply_team_lines!, @pricing, lines, other)
    end
  end

  test "custo no BDI: valores zerados no cadastro, sem esforço na sugestão, fora do rateio da planilha" do
    diretora = professionals(:diretora)
    diretora.update!(cost_in_bdi: true, rate_man_hour: 300)
    assert_equal [ 0, 0 ], [ diretora.rate_man_hour, diretora.rate_daily ]

    lines = [ { "professional_id" => diretora.id, "deliverable_name" => "Direção", "man_hours" => 40, "field_days" => 3 } ]
    @proposal.send(:apply_team_lines!, @pricing, lines, @item)
    line = @pricing.proposal_professionals.find_by(professional: diretora, deliverable_name: "Direção")
    assert_equal [ 0, 0 ], [ line.man_hours, line.field_days ]

    catalog = Spreadsheets::FactCatalog.new(@proposal)
    assert_not catalog["L#{line.id}"].piece
    assert_includes stub_class_method(Rag::PrecedentFinder, :new, ->(*) { raise "sem acervo" }) { @proposal.send(:team_suggestion_prompt) }, "CUSTO NO BDI"
  end
end
