require "test_helper"

class ScheduleItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:two)
    @conversation = conversations(:priced_conversation)
    @pricing = proposals(:priced_proposal).project_pricing
  end

  test "create adds a schedule item with an auto-incremented position within its type" do
    @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Contrato",
      start_period: 1, duration_periods: 1, position: 0)

    assert_difference "@pricing.schedule_items.count", 1 do
      post conversation_proposal_schedule_items_path(@conversation), params: {
        schedule_item: { schedule_type: "servico", phase_name: "Mobilização", activity_name: "Kick-off",
                          start_period: 1, duration_periods: 1, milestone: "0" }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
    line = @pricing.schedule_items.order(:created_at).last
    assert_equal 1, line.position
  end

  test "create rejects a line with no activity_name" do
    assert_no_difference "@pricing.schedule_items.count" do
      post conversation_proposal_schedule_items_path(@conversation), params: {
        schedule_item: { schedule_type: "servico", phase_name: "Mobilização", activity_name: "",
                          start_period: 1, duration_periods: 1 }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "create refuses to add a line to an approved proposal" do
    proposals(:priced_proposal).update!(status: "approved")

    assert_no_difference "@pricing.schedule_items.count" do
      post conversation_proposal_schedule_items_path(@conversation), params: {
        schedule_item: { schedule_type: "servico", phase_name: "Mobilização", activity_name: "Contrato",
                          start_period: 1, duration_periods: 1 }
      }
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "destroy removes the item" do
    item = @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Contrato",
      start_period: 1, duration_periods: 1, position: 0)

    assert_difference "@pricing.schedule_items.count", -1 do
      delete conversation_proposal_schedule_item_path(@conversation, item)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end

  test "destroy refuses to remove a line from an approved proposal" do
    item = @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização", activity_name: "Contrato",
      start_period: 1, duration_periods: 1, position: 0)
    proposals(:priced_proposal).update!(status: "approved")

    assert_no_difference "@pricing.schedule_items.count" do
      delete conversation_proposal_schedule_item_path(@conversation, item)
    end

    assert_redirected_to conversation_proposal_path(@conversation)
  end
end
