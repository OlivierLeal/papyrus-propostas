require "test_helper"

class ProcessLegalNormsJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
    @conversation.update!(processing_steps: { "et" => "done", "cal" => "pending", "tr" => "pending", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })
  end

  def achado!(field: "municipios", value: "Prado")
    @conversation.project_findings.create!(field: field, value: value, nature: "fato", source_kind: "et")
  end

  def cal_reply(campo: "condicionantes", valor: "Portaria X exige EMI", trecho: "trecho literal da norma", local: "NL1 — Portaria X, INEMA, Estadual (CAL/Ius Natura)")
    { achados: [ { campo: campo, valor: valor, natureza: "fato", trecho: trecho, local: local } ] }.to_json
  end

  test "skips (no AI call) and still triggers ProcessTrJob when there's no município finding" do
    assert_no_enqueued_jobs(only: ProcessLegalNormsJob) do
      assert_enqueued_with(job: ProcessTrJob, args: [ @conversation.id ]) do
        ProcessLegalNormsJob.perform_now(@conversation.id)
      end
    end

    assert_equal "skipped", @conversation.reload.processing_step_status("cal")
    assert_empty @conversation.project_findings
  end

  test "records the AI's final achados with source_kind cal" do
    achado!

    stub_ai_complete(cal_reply) { ProcessLegalNormsJob.perform_now(@conversation.id) }

    finding = @conversation.project_findings.where(source_kind: "cal").sole
    assert_equal "condicionantes", finding.field
    assert_equal "Portaria X exige EMI", finding.value
    assert_includes finding.locator, "NL1"
    assert_equal "done", @conversation.reload.processing_step_status("cal")
  end

  test "registers SearchLegalNormsTool before asking, so the AI can actually search" do
    achado!
    registered_tools = []
    original_method = Conversation.instance_method(:with_tool)
    Conversation.define_method(:with_tool) { |tool| registered_tools << tool.class; self }

    begin
      stub_ai_complete(cal_reply) { ProcessLegalNormsJob.perform_now(@conversation.id) }
    ensure
      Conversation.define_method(:with_tool, original_method)
    end

    assert_includes registered_tools, SearchLegalNormsTool
  end

  test "triggers ProcessTrJob after finishing successfully, when tr is pending" do
    achado!

    assert_enqueued_with(job: ProcessTrJob, args: [ @conversation.id ]) do
      stub_ai_complete(cal_reply) { ProcessLegalNormsJob.perform_now(@conversation.id) }
    end
  end

  test "does not trigger ProcessTrJob when tr is already skipped (no TR attachment)" do
    achado!
    @conversation.update!(processing_steps: @conversation.processing_steps.merge("tr" => "skipped"))

    assert_no_enqueued_jobs(only: ProcessTrJob) do
      stub_ai_complete(cal_reply) { ProcessLegalNormsJob.perform_now(@conversation.id) }
    end
  end

  test "marks cal as failed and still triggers ProcessTrJob when the AI call errors out" do
    achado!

    assert_enqueued_with(job: ProcessTrJob, args: [ @conversation.id ]) do
      stub_ai_error { ProcessLegalNormsJob.perform_now(@conversation.id) }
    end

    assert_equal "failed", @conversation.reload.processing_step_status("cal")
  end

  test "does not trigger GenerateSummaryJob while comp_docs is still pending" do
    achado!
    @conversation.update!(processing_steps: @conversation.processing_steps.merge("comp_docs" => "pending"))

    assert_no_enqueued_jobs(only: GenerateSummaryJob) do
      stub_ai_complete(cal_reply) { ProcessLegalNormsJob.perform_now(@conversation.id) }
    end
  end
end
