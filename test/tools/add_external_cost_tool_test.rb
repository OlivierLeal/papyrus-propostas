require "test_helper"

class AddExternalCostToolTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @tool = AddExternalCostTool.new(proposal: @proposal)
  end

  test "appends the external cost and recalculates the total" do
    original_total = @proposal.project_pricing.total_value

    result = JSON.parse(@tool.execute(descricao: "ART de fauna", valor: 500))

    assert result["success"]
    assert_equal "ART de fauna", result["descricao"]
    assert_equal 500.0, result["valor"]

    pricing = @proposal.project_pricing.reload
    assert_includes pricing.external_costs, { "description" => "ART de fauna", "value" => 500.0 }
    assert_equal original_total + 500, pricing.total_value
    assert_equal pricing.total_value.to_f, result["total_atualizado"].to_f
  end

  test "strips the description and coerces a string value" do
    @tool.execute(descricao: "  ART de flora  ", valor: "350.50")

    cost = @proposal.project_pricing.reload.external_costs.last
    assert_equal "ART de flora", cost["description"]
    assert_equal 350.50, cost["value"]
  end

  test "rejects a blank description without touching external_costs" do
    result = JSON.parse(@tool.execute(descricao: "   ", valor: 100))

    assert result["error"].present?
    assert_empty @proposal.project_pricing.reload.external_costs
  end

  test "rejects a value of zero or less" do
    result = JSON.parse(@tool.execute(descricao: "ART de fauna", valor: 0))

    assert result["error"].present?
    assert_empty @proposal.project_pricing.reload.external_costs
  end

  test "refuses when the proposal is already approved" do
    @proposal.update!(status: "approved")

    result = JSON.parse(@tool.execute(descricao: "ART de fauna", valor: 500))

    assert result["error"].present?
    assert_empty @proposal.project_pricing.reload.external_costs
  end

  test "returns a friendly error and does not raise when recalculation blows up" do
    # Minitest 6.0.6 não empacota minitest/mock aqui (sem Object#stub) — mesmo padrão já usado
    # em GenerateProposalDocumentToolTest: redefine o método na classe e restaura no ensure.
    original_recalculate = ProjectPricing.instance_method(:recalculate!)
    ProjectPricing.define_method(:recalculate!) { raise "boom" }

    begin
      result = JSON.parse(@tool.execute(descricao: "ART de fauna", valor: 500))
      assert result["error"].present?
    ensure
      ProjectPricing.define_method(:recalculate!, original_recalculate)
    end
  end

  test "refuses when the proposal has no project_pricing yet" do
    conversation = conversations(:reviewing_conversation)
    proposal = conversation.create_proposal!(status: "draft")
    tool = AddExternalCostTool.new(proposal: proposal)

    result = JSON.parse(tool.execute(descricao: "ART de fauna", valor: 500))

    assert result["error"].present?
  end
end
