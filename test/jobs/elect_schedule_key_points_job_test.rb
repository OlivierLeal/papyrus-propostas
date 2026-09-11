require "test_helper"

class ElectScheduleKeyPointsJobTest < ActiveJob::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
    @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Mobilização",
      activity_name: "Contrato", start_period: 1, duration_periods: 1, position: 0)
    @pricing.schedule_items.create!(schedule_type: "servico", phase_name: "Protocolo",
      activity_name: "Protocolo no órgão", start_period: 6, duration_periods: 1, milestone: true, position: 1)
  end

  test "elects the marcos from an existing servico schedule" do
    ai_response = '{"marcos_infografico": [{"nome": "Contrato", "periodo": 1}, {"nome": "Protocolo", "periodo": 6}]}'

    stub_ai_complete(ai_response) { ElectScheduleKeyPointsJob.new.perform(@proposal.id) }

    assert_equal [ 1, 6 ], @pricing.reload.schedule_key_points.map { |m| m["periodo"] }
  end

  test "does nothing when schedule_key_points is already populated (idempotente)" do
    @pricing.update!(schedule_key_points: [ { "nome" => "Já eleito", "periodo" => 2 } ])

    stub_ai_error { ElectScheduleKeyPointsJob.new.perform(@proposal.id) }

    assert_equal [ "Já eleito" ], @pricing.reload.schedule_key_points.map { |m| m["nome"] }
  end

  test "does nothing when there is no servico schedule" do
    @pricing.schedule_items.destroy_all

    assert_nothing_raised { ElectScheduleKeyPointsJob.new.perform(@proposal.id) }
    assert_empty @pricing.reload.schedule_key_points
  end

  test "does not raise when the proposal id does not exist" do
    assert_nothing_raised { ElectScheduleKeyPointsJob.new.perform(-1) }
  end

  test "logs and swallows the error instead of raising when the AI call fails" do
    assert_nothing_raised do
      stub_ai_error { ElectScheduleKeyPointsJob.new.perform(@proposal.id) }
    end
    assert_empty @pricing.reload.schedule_key_points
  end
end
