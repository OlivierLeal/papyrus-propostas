require "test_helper"

class TermOfReferenceToolsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @conversation = conversations(:priced_conversation)
  end

  test "set_term_of_reference: o arquivo enviado no chat vira o TR da proposta" do
    message = @conversation.messages.create!(role: "user", content: "segue o TR do órgão")
    message.attachments.attach(io: StringIO.new("%PDF-1.4"), filename: "TR INEMA eólica.pdf")

    result = JSON.parse(SetTermOfReferenceTool.new(conversation: @conversation).execute(arquivo: "inema"))
    assert result["success"]
    perform_enqueued_jobs(only: AcceptTermOfReferenceJob)

    candidate = @conversation.term_of_reference_candidates.last
    assert candidate.accepted?
    assert_equal "consultor", candidate.source
    assert_equal [ "TR INEMA eólica.pdf" ], @conversation.term_of_reference_attachments.map { |a| a.filename.to_s }
  end

  test "find_term_of_reference enfileira a busca forçada; com TR do cliente, avisa" do
    assert_enqueued_with(job: FindTermOfReferenceJob, args: [ @conversation.id, { force: true } ]) do
      FindTermOfReferenceTool.new(conversation: @conversation).execute
    end

    message = @conversation.messages.create!(role: "user", content: "setup")
    message.attachments.attach(io: StringIO.new("%PDF"), filename: "TR.pdf", metadata: { kind: "tr" })
    assert JSON.parse(FindTermOfReferenceTool.new(conversation: @conversation).execute)["aviso"]
  end

  # PTC26047 (2026-10): o consultor pediu "incluir o TR no anexo", o card ficou pendente e a revisão
  # disse que o TR estava no Anexo I sem estar. A IA agora aceita o TR encontrado pelo chat.
  test "set_term_of_reference com usar_encontrado aceita o TR que o sistema achou" do
    candidate = @conversation.term_of_reference_candidates.create!(source: "internet", title: "TR eólica", url: "https://exemplo.gov.br/tr.pdf", status: "pending")

    assert_enqueued_with(job: AcceptTermOfReferenceJob, args: [ candidate.id ]) do
      result = JSON.parse(SetTermOfReferenceTool.new(conversation: @conversation).execute(usar_encontrado: true))
      assert result["success"]
    end
    assert candidate.reload.accepting?
    assert JSON.parse(SetTermOfReferenceTool.new(conversation: @conversation).execute(usar_encontrado: true))["error"]
  end
end
