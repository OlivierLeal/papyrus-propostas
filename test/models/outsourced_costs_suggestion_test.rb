require "test_helper"

# Conversa 79 (2026-10-16): serviço 100% terceirizado, propostas do fornecedor anexadas como
# complementares — os custos não entravam sozinhos e a sugestão ainda criava campo de logística
# pro técnico do fornecedor.
class OutsourcedCostsSuggestionTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @pricing.update!(external_costs: [])
  end

  test "custos terceirizados da sugestão entram como Serviços Terceirizados, com achado de origem" do
    suggestion = { "itens" => [], "custos_terceirizados" => [
      { "descricao" => "Estudo de Dispersão Atmosférica (EDA) – ENGEAR", "valor" => 15000, "documento" => "ENG_26257.pdf" },
      { "descricao" => "Monitoramento da Qualidade do Ar – ENGEAR", "valor" => 22000.0 }
    ] }

    @proposal.send(:apply_team_suggestion!, @pricing, suggestion)

    costs = @pricing.reload.external_costs
    assert_equal [ 15000.0, 22000.0 ], costs.map { |cost| cost["value"] }
    assert costs.all? { |cost| cost["kind"] == "terceirizado" }
    assert_equal 2, @pricing.outsourced_costs.size
    assert @proposal.conversation.project_findings.exists?([ "value LIKE ?", "%ENG_26257.pdf%" ])
  end

  test "não duplica custo já lançado e ignora valor ausente ou em texto" do
    @pricing.update!(external_costs: [ { "description" => "Monitoramento da Qualidade do Ar – ENGEAR", "value" => 22000.0 } ])
    suggestion = { "itens" => [], "custos_terceirizados" => [
      { "descricao" => "monitoramento da qualidade do ar – engear", "valor" => 22000 },
      { "descricao" => "Laboratório", "valor" => "R$ 5.000" },
      { "descricao" => "", "valor" => 100 }
    ] }

    @proposal.send(:apply_team_suggestion!, @pricing, suggestion)

    assert_equal 1, @pricing.reload.external_costs.size
  end

  test "o prompt de equipe proíbe equipe e campo para a frente terceirizada" do
    prompt = stub_class_method(Rag::PrecedentFinder, :new, ->(*) { raise "sem acervo" }) { @proposal.send(:team_suggestion_prompt) }

    assert_includes prompt, "SERVIÇO TERCEIRIZADO"
    assert_includes prompt, "custos_terceirizados"
  end
end
