require "test_helper"

# Trava de confirmação do enquadramento (relato da Sara, 2026-09-29: "estou lendo o resumo no
# automático e já peço pra gerar" — o enquadramento diferente do sistema só apareceu com a proposta
# pronta). Antes de precificar ou gerar o 1º documento, um consultor confirma licença e estudo.
class FramingConfirmationTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = conversations(:reviewing_conversation)
    @conversation.update!(framing_confirmed_at: nil)
    sign_in_as users(:one)
  end

  def open_legal_conflict!
    requested = @conversation.project_findings.create!(field: "tipo_estudo", value: "rap", nature: "fato", source_kind: "et")
    legal = @conversation.project_findings.create!(field: "tipo_estudo", value: "eia_rima", nature: "fato", source_kind: "cal")
    @conversation.project_conflicts.create!(field: "tipo_estudo", summary: "Lei × ET.").tap do |conflict|
      [ requested, legal ].each { |f| conflict.project_conflict_findings.create!(project_finding: f) }
    end
  end

  test "sem confirmação, a ferramenta não gera e diz onde se resolve" do
    result = JSON.parse(GenerateProposalDocumentTool.new(conversation: @conversation).execute(nome_cliente: "X"))

    assert_includes result["error"], "Confirmar enquadramento"
    assert_nil @conversation.reload.proposal
  end

  test "sem confirmação, não avança para a precificação" do
    post conversation_proposal_path(@conversation)

    assert_redirected_to conversation_path(@conversation)
    assert_nil @conversation.reload.proposal
  end

  test "o painel mostra o enquadramento e o topo pede a confirmação; o avanço não aparece" do
    @conversation.project_findings.create!(field: "tipo_licenca", value: "LP", nature: "fato", source_kind: "et")

    get conversation_path(@conversation)

    assert_select "h2", text: "Enquadramento"
    assert_select "dd", text: "LP"
    # A ação principal do cabeçalho vira "Confirmar enquadramento"; o avanço pra precificação nem aparece.
    assert_select "#proposal_header form[action=?]", confirm_framing_conversation_path(@conversation)
    assert_select "#proposal_header button", text: "Confirmar enquadramento"
    assert_select "form[action=?]", conversation_proposal_path(@conversation), count: 0
  end

  # 2026-10-08, conversa 70: a aba Pendências dizia "Nada travando" com o enquadramento por confirmar.
  test "a aba Pendências mostra o enquadramento por confirmar, com o botão e no contador" do
    get conversation_path(@conversation)

    assert_select "#generation_blockers form[action=?]", confirm_framing_conversation_path(@conversation)
    assert_select "#generation_blockers", text: /Nada travando/, count: 0
  end

  test "confirmar registra quem e quando, e libera" do
    post confirm_framing_conversation_path(@conversation)

    @conversation.reload
    assert_equal users(:one), @conversation.framing_confirmed_by
    assert_not @conversation.framing_confirmation_required?
  end

  test "com divergência lei × pedido em aberto, não dá pra confirmar antes de decidir" do
    conflict = open_legal_conflict!

    post confirm_framing_conversation_path(@conversation)
    assert @conversation.reload.framing_confirmation_required?

    conflict.refer_to_client!(users(:one))
    post confirm_framing_conversation_path(@conversation)
    assert_not @conversation.reload.framing_confirmation_required?
  end

  test "o estado da proposta avisa a IA pra não gerar enquanto não houver confirmação" do
    @conversation.refresh_proposal_state_snapshot!
    text = @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last.content

    assert_includes text, "[BLOQUEIO: ENQUADRAMENTO NÃO CONFIRMADO]"
  end

  test "proposta que já tem documento gerado não trava (anterior à confirmação)" do
    proposal = proposals(:priced_proposal)
    proposal.conversation.update!(framing_confirmed_at: nil)
    proposal.generated_documents.attach(io: StringIO.new("docx"), filename: "PTC.docx")

    assert_not proposal.conversation.reload.framing_confirmation_required?
  end
end
