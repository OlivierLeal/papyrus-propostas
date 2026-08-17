require "test_helper"

class GenerateSummaryJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "summary" => "queued" })
  end

  test "asks the AI for a summary, marks summary done and moves status to reviewing" do
    stub_ai_complete("# RESUMO ESTRUTURADO\n\nTudo certo.") { GenerateSummaryJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("summary")
    assert_equal "reviewing", @conversation.status
  end

  test "the summary reply is visible to the consultant, only the instruction is hidden" do
    stub_ai_complete("# RESUMO ESTRUTURADO") { GenerateSummaryJob.perform_now(@conversation.id) }

    instruction = @conversation.messages.where(role: "user", internal: true).last
    reply = @conversation.messages.where(role: "assistant").last

    assert instruction.present?
    assert_not reply.internal?
  end

  test "includes parsed JSON findings from prior assistant messages in the prompt" do
    @conversation.messages.create!(role: "assistant", content: '{"tipo_licenca": "LP", "diagnosticos": ["fauna", "flora"]}', internal: true)

    sent_prompt = nil
    stub_ai_complete("ok") do
      GenerateSummaryJob.perform_now(@conversation.id)
    end
    # A instrução enviada é a última mensagem "user" internal antes da resposta.
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "tipo_licenca: LP"
    assert_includes sent_prompt, "diagnosticos: fauna; flora"
  end

  test "ignores prior assistant messages whose content isn't valid JSON" do
    @conversation.messages.create!(role: "assistant", content: "isso não é json, é texto livre", internal: true)
    @conversation.messages.create!(role: "assistant", content: '{"tipo_licenca": "LP"}', internal: true)

    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "tipo_licenca: LP"
    assert_not_includes sent_prompt, "isso não é json"
  end

  test "falls back to a placeholder message when there is no structured data yet" do
    sent_prompt = nil
    stub_ai_complete("ok") { GenerateSummaryJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "Nenhum dado estruturado disponível ainda."
  end

  test "marks summary as failed and does not raise when the AI call errors out" do
    stub_ai_error { GenerateSummaryJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("summary")
    assert_equal "processing", @conversation.status # não avança de status quando falha
  end
end
