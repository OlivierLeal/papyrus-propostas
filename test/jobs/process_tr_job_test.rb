require "test_helper"

class ProcessTrJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
  end

  test "marks tr as skipped and still checks completion when there is no TR attachment" do
    # processing_conversation já tem comp_docs: skipped — sem TR anexado, os dois passos resolvem
    # e check_processing_complete! deve disparar o GenerateSummaryJob (sem executá-lo de verdade).
    assert_enqueued_with(job: GenerateSummaryJob, args: [ @conversation.id ]) do
      ProcessTrJob.perform_now(@conversation.id)
    end

    assert_equal "skipped", @conversation.reload.processing_step_status("tr")
  end

  test "processes the TR attachment, hides the instruction and the reply, and marks done" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    stub_ai_complete('{"tipo_licenca": "LP"}') { ProcessTrJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("tr")

    instruction = @conversation.messages.where(role: "user", internal: true).last
    reply = @conversation.messages.where(role: "assistant").last
    assert instruction.present?
    assert reply.present?
    assert reply.internal? # ProcessTrJob usa hide_response: true — o JSON bruto não é pro consultor ver
  end

  test "marks tr as failed and does not raise when the AI call errors out" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    stub_ai_error { ProcessTrJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("tr")
  end

  test "does not trigger GenerateSummaryJob while comp_docs is still pending" do
    @conversation.update!(processing_steps: { "tr" => "pending", "comp_docs" => "pending", "summary" => "pending" })

    assert_no_enqueued_jobs(only: GenerateSummaryJob) do
      ProcessTrJob.perform_now(@conversation.id)
    end
  end
end
