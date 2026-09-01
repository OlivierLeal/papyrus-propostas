require "test_helper"

class ProcessEtJobTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
  end

  # A extração devolve uma lista de achados, cada um com a prova de onde saiu (ver
  # ProjectFindings::Recorder).
  def et_reply(campo:, valor:, natureza: "fato", trecho: "trecho literal do ET", local: "item 3.1")
    { achados: [ { campo: campo, valor: valor, natureza: natureza, trecho: trecho, local: local } ] }.to_json
  end

  def attach_et!(filename: "et.pdf")
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: filename, content_type: "application/pdf", metadata: { kind: "et" }
    )
    message
  end

  test "records each finding with its evidence and the document it came from" do
    attach_et!

    stub_ai_complete(et_reply(campo: "orgao_ambiental", valor: "INEMA", trecho: "...protocolo junto ao INEMA...", local: "item 2")) do
      ProcessEtJob.perform_now(@conversation.id)
    end

    finding = @conversation.project_findings.sole
    assert_equal "orgao_ambiental", finding.field
    assert_equal "INEMA", finding.value
    assert_equal "fato", finding.nature
    assert_equal "et", finding.source_kind
    assert_equal "item 2", finding.locator
    assert_includes finding.excerpt, "INEMA"
    assert_equal "et.pdf", finding.document_name
  end

  test "marks et as skipped and still checks completion when there is no ET attachment" do
    # processing_conversation já tem comp_docs/tr: skipped — sem ET anexado, os passos resolvem
    # e check_processing_complete! deve disparar o GenerateSummaryJob (sem executá-lo de verdade).
    assert_enqueued_with(job: GenerateSummaryJob, args: [ @conversation.id ]) do
      ProcessEtJob.perform_now(@conversation.id)
    end

    assert_equal "skipped", @conversation.reload.processing_step_status("et")
  end

  test "processes the ET attachment, hides the instruction and the reply, and marks done" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf",
      metadata: { kind: "et" }
    )

    stub_ai_complete(et_reply(campo: "tipo_licenca", valor: "LP")) { ProcessEtJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("et")

    instruction = @conversation.messages.where(role: "user", internal: true).last
    reply = @conversation.messages.where(role: "assistant").last
    assert instruction.present?
    assert reply.present?
    assert reply.internal? # ProcessEtJob usa hide_response: true — o JSON bruto não é pro consultor ver
  end

  test "sends every ET attachment together in a single call, not one per file" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "anexo_et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    stub_ai_complete(et_reply(campo: "tipo_licenca", valor: "LP")) { ProcessEtJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("et")
    # Uma instrução e uma resposta só — os dois arquivos foram lidos juntos, não em duas chamadas.
    assert_equal 1, @conversation.messages.where(role: "user", internal: true).count
    assert_equal 1, @conversation.messages.where(role: "assistant").count
  end

  test "assigns the study type when the AI answers with a real code from the menu" do
    @conversation.update_column(:study_type_id, nil)
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    stub_ai_complete(et_reply(campo: "tipo_estudo", valor: "eia_rima")) { ProcessEtJob.perform_now(@conversation.id) }

    assert_equal study_types(:eia_rima), @conversation.reload.study_type
  end

  test "the prompt lists the real study_type menu and asks for one of its codes" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    stub_ai_complete(et_reply(campo: "tipo_estudo", valor: "eia_rima")) { ProcessEtJob.perform_now(@conversation.id) }
    sent_prompt = @conversation.messages.where(role: "user", internal: true).order(:created_at).last.content

    assert_includes sent_prompt, "código: eia_rima"
    assert_includes sent_prompt, "código: rap"
  end

  test "assigns the study type even when the AI wraps the JSON reply in markdown fences" do
    # Achado em teste manual com IA real: o Gemini/Bedrock às vezes ignora "sem markdown" e
    # embrulha em ```json ... ``` — sem tirar isso antes do parse, a atribuição falhava em
    # silêncio (ver AiJsonResponse).
    @conversation.update_column(:study_type_id, nil)
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    fenced_reply = "```json\n#{et_reply(campo: "tipo_estudo", valor: "eia_rima")}\n```"
    stub_ai_complete(fenced_reply) { ProcessEtJob.perform_now(@conversation.id) }

    assert_equal study_types(:eia_rima), @conversation.reload.study_type
  end

  test "does not assign a study type when the AI invents a code outside the menu" do
    @conversation.update_column(:study_type_id, nil)
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    stub_ai_complete(et_reply(campo: "tipo_estudo", valor: "tipo_que_nao_existe")) { ProcessEtJob.perform_now(@conversation.id) }

    assert_nil @conversation.reload.study_type_id
  end

  test "does not assign a study type and does not raise when the AI reply isn't valid JSON" do
    @conversation.update_column(:study_type_id, nil)
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf", metadata: { kind: "et" }
    )

    stub_ai_complete("isso não é json") { ProcessEtJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("et")
    assert_nil @conversation.study_type_id
  end

  test "does not overwrite a study type that was already set" do
    original = @conversation.study_type

    stub_ai_complete('{"tipo_estudo_codigo": "rap"}') { ProcessEtJob.perform_now(@conversation.id) }

    assert_equal original, @conversation.reload.study_type
  end

  test "marks et as failed and does not raise when the AI call errors out" do
    message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "et.pdf", content_type: "application/pdf",
      metadata: { kind: "et" }
    )

    stub_ai_error { ProcessEtJob.perform_now(@conversation.id) }

    assert_equal "failed", @conversation.reload.processing_step_status("et")
  end

  test "does not trigger GenerateSummaryJob while comp_docs is still pending" do
    @conversation.update!(processing_steps: { "et" => "pending", "cal" => "skipped", "tr" => "skipped", "comp_docs" => "pending", "kmz" => "skipped", "summary" => "pending" })

    assert_no_enqueued_jobs(only: GenerateSummaryJob) do
      ProcessEtJob.perform_now(@conversation.id)
    end
  end

  # ENCADEAMENTO ET → CAL → TR (nunca em paralelo — ver Conversation::PROCESSING_STEPS): o TR
  # precisa esperar a pesquisa no CAL, porque só depois que o ET identifica o município é que dá
  # pra saber o âmbito certo pra pesquisar.
  test "enqueues ProcessLegalNormsJob (not ProcessTrJob) when cal is pending, regardless of the ET outcome" do
    attach_et!
    @conversation.update!(processing_steps: { "et" => "pending", "cal" => "pending", "tr" => "pending", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })

    assert_enqueued_with(job: ProcessLegalNormsJob, args: [ @conversation.id ]) do
      assert_no_enqueued_jobs(only: ProcessTrJob) do
        stub_ai_complete(et_reply(campo: "municipios", valor: "Prado")) { ProcessEtJob.perform_now(@conversation.id) }
      end
    end
  end

  test "enqueues ProcessLegalNormsJob even when the ET has no attachment at all (cal decides on its own if there's anything to search)" do
    @conversation.update!(processing_steps: { "et" => "pending", "cal" => "pending", "tr" => "pending", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })

    assert_enqueued_with(job: ProcessLegalNormsJob, args: [ @conversation.id ]) do
      ProcessEtJob.perform_now(@conversation.id)
    end

    assert_equal "skipped", @conversation.reload.processing_step_status("et")
  end

  test "enqueues ProcessTrJob directly when cal is skipped and tr is pending" do
    attach_et!
    @conversation.update!(processing_steps: { "et" => "pending", "cal" => "skipped", "tr" => "pending", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })

    assert_enqueued_with(job: ProcessTrJob, args: [ @conversation.id ]) do
      assert_no_enqueued_jobs(only: ProcessLegalNormsJob) do
        stub_ai_complete(et_reply(campo: "municipios", valor: "Prado")) { ProcessEtJob.perform_now(@conversation.id) }
      end
    end
  end

  test "enqueues neither ProcessLegalNormsJob nor ProcessTrJob when both cal and tr are already skipped" do
    attach_et!
    @conversation.update!(processing_steps: { "et" => "pending", "cal" => "skipped", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "skipped", "summary" => "pending" })

    assert_no_enqueued_jobs(only: [ ProcessLegalNormsJob, ProcessTrJob ]) do
      stub_ai_complete(et_reply(campo: "municipios", valor: "Prado")) { ProcessEtJob.perform_now(@conversation.id) }
    end
  end
end
