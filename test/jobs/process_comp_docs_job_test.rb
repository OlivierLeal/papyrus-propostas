require "test_helper"

class ProcessCompDocsJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
  end

  test "marks comp_docs as skipped when there are no complementary attachments" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "pending", "summary" => "pending" })

    ProcessCompDocsJob.perform_now(@conversation.id)

    assert_equal "skipped", @conversation.reload.processing_step_status("comp_docs")
  end

  test "processes every complementary attachment and marks done" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "pending", "summary" => "pending" })
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("proposta anterior"), filename: "proposta_antiga.pdf", content_type: "application/pdf",
      metadata: { kind: "complementary" }
    )
    message.attachments.attach(
      io: StringIO.new("resolucao"), filename: "resolucao.pdf", content_type: "application/pdf",
      metadata: { kind: "complementary" }
    )

    stub_ai_complete('{"tipo_documento": "proposta anterior"}') { ProcessCompDocsJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("comp_docs")
    # ask_internally é chamado uma vez por anexo, hide_response: true em cada.
    hidden_replies = @conversation.messages.where(role: "assistant", internal: true)
    assert_equal 2, hidden_replies.count
  end

  test "marks comp_docs as failed and does not raise when the AI call errors out" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "pending", "summary" => "pending" })
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("proposta anterior"), filename: "proposta_antiga.pdf", content_type: "application/pdf",
      metadata: { kind: "complementary" }
    )

    stub_ai_error { ProcessCompDocsJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("comp_docs")
  end

  test "triggers GenerateSummaryJob once tr is already resolved" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "pending", "kmz" => "skipped", "summary" => "pending" })

    assert_enqueued_with(job: GenerateSummaryJob, args: [ @conversation.id ]) do
      ProcessCompDocsJob.perform_now(@conversation.id)
    end
  end
end
