require "test_helper"

class ProcessTrJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
  end

  # A extração devolve uma lista de achados, cada um com a prova de onde saiu (ver
  # ProjectFindings::Recorder).
  def tr_reply(campo:, valor:, natureza: "fato", trecho: "trecho literal do TR", local: "item 3.1")
    { achados: [ { campo: campo, valor: valor, natureza: natureza, trecho: trecho, local: local } ] }.to_json
  end

  def attach_tr!(filename: "tr.pdf")
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: filename, content_type: "application/pdf", metadata: { kind: "tr" }
    )
    message
  end

  test "records each finding with its evidence and the document it came from" do
    attach_tr!

    stub_ai_complete(tr_reply(campo: "condicionantes", valor: "Plano de monitoramento de fauna", trecho: "...plano de monitoramento de fauna...", local: "item 4")) do
      ProcessTrJob.perform_now(@conversation.id)
    end

    finding = @conversation.project_findings.sole
    assert_equal "condicionantes", finding.field
    assert_equal "Plano de monitoramento de fauna", finding.value
    assert_equal "fato", finding.nature
    assert_equal "tr", finding.source_kind
    assert_equal "item 4", finding.locator
    assert_includes finding.excerpt, "fauna"
    assert_equal "tr.pdf", finding.document_name
  end

  test "marks tr as skipped and still checks completion when there is no TR attachment" do
    # processing_conversation já tem et: pending — sem TR anexado, este job só marca tr como
    # skipped e não dispara o resumo sozinho (falta o ET ainda).
    ProcessTrJob.perform_now(@conversation.id)

    assert_equal "skipped", @conversation.reload.processing_step_status("tr")
  end

  test "processes the TR attachment, hides the instruction and the reply, and marks done" do
    attach_tr!

    stub_ai_complete(tr_reply(campo: "tipo_licenca", valor: "LP")) { ProcessTrJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("tr")

    instruction = @conversation.messages.where(role: "user", internal: true).last
    reply = @conversation.messages.where(role: "assistant").last
    assert instruction.present?
    assert reply.present?
    assert reply.internal? # ProcessTrJob usa hide_response: true — o JSON bruto não é pro consultor ver
  end

  test "sends every TR attachment together in a single call, not one per file" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf", metadata: { kind: "tr" }
    )
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "anexo_tr.pdf", content_type: "application/pdf", metadata: { kind: "tr" }
    )

    stub_ai_complete(tr_reply(campo: "tipo_licenca", valor: "LP")) { ProcessTrJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("tr")
    assert_equal 1, @conversation.messages.where(role: "user", internal: true).count
    assert_equal 1, @conversation.messages.where(role: "assistant").count
  end

  test "assigns the study type when the ET hasn't set one yet and the TR answers with a real code from the menu" do
    @conversation.update_column(:study_type_id, nil)
    attach_tr!

    stub_ai_complete(tr_reply(campo: "tipo_estudo", valor: "eia_rima")) { ProcessTrJob.perform_now(@conversation.id) }

    assert_equal study_types(:eia_rima), @conversation.reload.study_type
  end

  test "does not overwrite a study type that was already set (ex.: pelo ET)" do
    original = @conversation.study_type
    attach_tr!

    stub_ai_complete(tr_reply(campo: "tipo_estudo", valor: "rap")) { ProcessTrJob.perform_now(@conversation.id) }

    assert_equal original, @conversation.reload.study_type
  end

  test "marks tr as failed and does not raise when the AI call errors out" do
    attach_tr!

    stub_ai_error { ProcessTrJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("tr")
  end

  test "does not trigger GenerateSummaryJob while et is still pending" do
    @conversation.update!(processing_steps: { "et" => "pending", "tr" => "pending", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })

    assert_no_enqueued_jobs(only: GenerateSummaryJob) do
      ProcessTrJob.perform_now(@conversation.id)
    end
  end
end
