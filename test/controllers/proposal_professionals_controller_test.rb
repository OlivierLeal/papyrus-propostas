require "test_helper"

class ProposalProfessionalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:two)
    @conversation = conversations(:priced_conversation)
    @pricing = proposals(:priced_proposal).project_pricing
  end

  test "create adds a line outside the study_templates menu and recalculates the total" do
    assert_difference "@pricing.proposal_professionals.count", 1 do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: {
          professional_id: professionals(:inativo).id, deliverable_name: "Consultoria extra", hours_office: "10", hours_field: "0"
        }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    line = @pricing.proposal_professionals.order(:created_at).last
    assert_equal 10 * professionals(:inativo).rate_office * @pricing.bdi * @pricing.tax_multiplier, line.subtotal
  end

  test "create rejects a line with no deliverable_name" do
    assert_no_difference "@pricing.proposal_professionals.count" do
      post conversation_proposal_proposal_professionals_path(@conversation), params: {
        proposal_professional: { professional_id: professionals(:inativo).id, deliverable_name: "", hours_office: "10", hours_field: "0" }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "destroy removes the line and recalculates the total" do
    line = proposal_professionals(:coordenacao_line)

    assert_difference "@pricing.proposal_professionals.count", -1 do
      delete conversation_proposal_proposal_professional_path(@conversation, line)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    assert_not_includes @pricing.reload.proposal_professionals, line
  end
end
