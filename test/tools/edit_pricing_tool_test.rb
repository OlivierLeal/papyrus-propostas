require "test_helper"

# Conversa 79 (2026-10-16): a IA não tinha como tirar a logística duplicada do terceirizado e tentou
# lançar um custo externo negativo.
class EditPricingToolTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @tool = EditPricingTool.new(proposal: @proposal)
  end

  test "remove o campo de logística e recalcula" do
    campaign = field_campaigns(:campo_servico)

    result = JSON.parse(@tool.execute(acao: "remover_campo", id: campaign.id))

    assert result["success"], result["error"]
    assert_not FieldCampaign.exists?(campaign.id)
    assert_equal @pricing.reload.total_value.to_f, result["total_atualizado"].to_f
  end

  test "remove o custo externo pelo número" do
    @pricing.update!(external_costs: [ { "description" => "ART", "value" => 100.0 }, { "description" => "Laboratório", "value" => 900.0 } ])

    result = JSON.parse(@tool.execute(acao: "remover_custo_externo", id: 2))

    assert result["success"], result["error"]
    assert_equal [ "ART" ], @pricing.reload.external_costs.map { |cost| cost["description"] }
  end

  test "equipe fixa não sai da equipe" do
    fixed = @pricing.proposal_professionals.first
    fixed.professional.update!(always_included: true)

    result = JSON.parse(@tool.execute(acao: "remover_linha_equipe", id: fixed.id))

    assert result["error"].present?
    assert ProposalProfessional.exists?(fixed.id)
  end

  test "campo de outra proposta não é encontrado" do
    result = JSON.parse(@tool.execute(acao: "remover_campo", id: 0))

    assert_match "Não achei", result["error"]
  end

  test "proposta aprovada fica travada" do
    @proposal.update_column(:status, "approved")

    result = JSON.parse(@tool.execute(acao: "remover_campo", id: field_campaigns(:campo_servico).id))

    assert_match "aprovada", result["error"]
    assert FieldCampaign.exists?(field_campaigns(:campo_servico).id)
  end
end
