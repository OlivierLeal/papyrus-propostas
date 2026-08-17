require "test_helper"

class ProposalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:two)
    @conversation = conversations(:priced_conversation)
    @proposal = proposals(:priced_proposal)
  end

  test "show renders the pricing screen" do
    get conversation_proposal_path(@conversation)
    assert_response :success
  end

  test "create builds an AI-suggested team and moves the conversation into pricing" do
    reviewing = conversations(:reviewing_conversation)
    sign_in_as reviewing.user
    ai_response = { linhas: [], documentos_separados: false }.to_json

    stub_ai_complete(ai_response) { post conversation_proposal_path(reviewing) }

    reviewing.reload
    assert_equal "pricing", reviewing.status
    assert reviewing.proposal.present?
    assert_redirected_to conversation_proposal_path(reviewing)
  end

  test "create refuses when the conversation is not in reviewing status" do
    post conversation_proposal_path(@conversation) # priced_conversation já está em "pricing"

    assert_redirected_to @conversation
    follow_redirect!
    assert_match "só pode ser precificada", response.body
  end

  test "update recalculates pricing and marks the proposal as priced" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "1.30", tax_multiplier: "1.25", distance_km: "120", logistics_days: "4",
                          rental_per_day: "160", meal_per_day: "90", fuel_total: "600" },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    @proposal.reload
    assert_equal "priced", @proposal.status
    assert_equal 1.30, @proposal.project_pricing.reload.bdi
  end

  test "update rejects invalid pricing params and keeps the proposal editable" do
    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "0", tax_multiplier: "1.25", distance_km: "1", logistics_days: "1",
                          rental_per_day: "1", meal_per_day: "1", fuel_total: "1" },
      proposal: { document_split: "combined" }
    }

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_not_equal "0.0", @proposal.reload.project_pricing.bdi.to_s
  end

  test "update is blocked once the proposal is approved" do
    @proposal.update!(status: "approved")

    patch conversation_proposal_path(@conversation), params: {
      project_pricing: { bdi: "2.0", tax_multiplier: "1.25", distance_km: "1", logistics_days: "1",
                          rental_per_day: "1", meal_per_day: "1", fuel_total: "1" },
      proposal: { document_split: "combined" }
    }

    follow_redirect!
    assert_match "já foi aprovada", response.body
  end

  test "approve locks the proposal and completes the conversation" do
    post approve_conversation_proposal_path(@conversation)

    @proposal.reload
    @conversation.reload
    assert_equal "approved", @proposal.status
    assert_equal "completed", @conversation.status
  end

  test "approve refuses a second time once already approved" do
    @proposal.update!(status: "approved")

    post approve_conversation_proposal_path(@conversation)

    follow_redirect!
    assert_match "já foi aprovada", response.body
  end

  test "add_external_cost appends a cost line and recalculates the total" do
    original_total = @proposal.project_pricing.total_value

    post add_external_cost_conversation_proposal_path(@conversation), params: { description: "ART", value: "350" }

    pricing = @proposal.project_pricing.reload
    assert_includes pricing.external_costs, { "description" => "ART", "value" => 350.0 }
    assert_equal original_total + 350, pricing.total_value
  end

  test "add_external_cost rejects a blank description or non-positive value" do
    assert_no_changes -> { @proposal.project_pricing.reload.external_costs } do
      post add_external_cost_conversation_proposal_path(@conversation), params: { description: "", value: "350" }
    end
  end

  test "remove_external_cost drops the cost at the given index and recalculates" do
    @proposal.project_pricing.update!(external_costs: [ { "description" => "ART", "value" => 350 } ])
    @proposal.project_pricing.recalculate!

    delete remove_external_cost_conversation_proposal_path(@conversation, index: 0)

    pricing = @proposal.project_pricing.reload
    assert_empty pricing.external_costs
  end
end
