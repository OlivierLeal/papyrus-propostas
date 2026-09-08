require "test_helper"

class SuggestScheduleJobTest < ActiveJob::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
  end

  test "suggests the schedule when there is a pricing and no items yet" do
    ai_response = '{"cronograma_servico": [{"fase": "Mobilização", "atividade": "Contrato", "periodo_inicio": 1, "duracao": 1, "marco": false}], "cronograma_implantacao": []}'

    stub_ai_complete(ai_response) { SuggestScheduleJob.new.perform(@proposal.id) }

    assert_equal 1, @proposal.project_pricing.schedule_items.count
  end

  test "does nothing when a schedule already exists (idempotente)" do
    @proposal.project_pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização",
      activity_name: "Contrato", start_period: 1, duration_periods: 1, position: 0)

    assert_no_difference "@proposal.project_pricing.schedule_items.count" do
      SuggestScheduleJob.new.perform(@proposal.id)
    end
  end

  test "does nothing when the proposal has no pricing" do
    proposal = conversations(:reviewing_conversation).create_proposal!(status: "draft", version: 1)

    assert_nothing_raised { SuggestScheduleJob.new.perform(proposal.id) }
  end

  test "does not raise when the proposal id does not exist" do
    assert_nothing_raised { SuggestScheduleJob.new.perform(-1) }
  end

  test "logs and swallows the error instead of raising when the AI call fails" do
    assert_nothing_raised do
      stub_ai_error { SuggestScheduleJob.new.perform(@proposal.id) }
    end
    assert_equal 0, @proposal.project_pricing.schedule_items.count
  end
end
