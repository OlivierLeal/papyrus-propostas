require "test_helper"

# Pendências e divergências TRAVAM a geração da proposta (2026-09-30, conversa 65: o resumo abriu três
# divergências e listou dúvidas de diárias/escala, e o consultor pediu "gere a primeira versão" sem
# responder nada). Quem trava é o código; o consultor libera respondendo ou com motivo.
class GenerationBlockersTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = conversations(:reviewing_conversation)
    sign_in_as users(:one)
  end

  def open_conflict!
    tr = @conversation.project_findings.create!(field: "area_ha", value: "500", nature: "fato", source_kind: "tr")
    kmz = @conversation.project_findings.create!(field: "area_ha", value: "620", nature: "fato", source_kind: "sistema")
    @conversation.project_conflicts.create!(field: "area_ha", summary: "TR diz 500 ha, KMZ mede 620.").tap do |conflict|
      [ tr, kmz ].each { |f| conflict.project_conflict_findings.create!(project_finding: f) }
    end
  end

  def generate
    JSON.parse(GenerateProposalDocumentTool.new(conversation: @conversation).execute(nome_cliente: "X"))
  end

  test "pendência aberta: a ferramenta não gera e lista o que falta responder" do
    @conversation.project_issues.create!(question: "As bacias Potiguar e Pará-Maranhão estão no escopo?")

    result = generate

    assert_includes result["error"], "As bacias Potiguar e Pará-Maranhão estão no escopo?"
    assert_nil @conversation.reload.proposal
  end

  test "divergência sem decisão também trava" do
    open_conflict!

    assert_includes generate["error"], "TR diz 500 ha, KMZ mede 620."
  end

  test "responder no card libera e a resposta vai pro estado que a IA lê" do
    issue = @conversation.project_issues.create!(question: "As bacias estão no escopo?")

    post answer_conversation_project_issue_path(@conversation, issue), params: { answer: "Sim, as duas entram." }, as: :turbo_stream

    assert issue.reload.answered?
    assert_equal users(:one), issue.resolved_by
    assert_empty @conversation.generation_blockers
    @conversation.refresh_proposal_state_snapshot!
    snapshot = @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last.content
    assert_includes snapshot, "RESPOSTA DO CONSULTOR: Sim, as duas entram."
  end

  test "seguir sem resposta exige motivo, e com motivo libera como ressalva" do
    issue = @conversation.project_issues.create!(question: "As diárias batem com a escala?")

    post waive_conversation_project_issue_path(@conversation, issue), params: { reason: " " }
    assert issue.reload.open?

    post waive_conversation_project_issue_path(@conversation, issue), params: { reason: "Cliente responde na fase de dúvidas." }
    assert issue.reload.waived?
    assert_empty @conversation.generation_blockers
  end

  test "divergência liberada sem decidir (com motivo) deixa de travar e vira ressalva" do
    conflict = open_conflict!

    post waive_conversation_project_conflict_path(@conversation, conflict), params: { reason: "Confirmar com o cliente." }

    assert conflict.reload.waived?
    assert_empty @conversation.generation_blockers
    @conversation.refresh_proposal_state_snapshot!
    snapshot = @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last.content
    assert_includes snapshot, "[DIVERGÊNCIAS LIBERADAS SEM DECISÃO]"
  end

  test "o card da pendência e o painel 'Antes de gerar' aparecem na tela" do
    issue = @conversation.project_issues.create!(question: "As bacias estão no escopo?")
    @conversation.messages.create!(role: "assistant", content: { project_issue_id: issue.id }.to_json)

    get conversation_path(@conversation)

    assert_select "##{ActionView::RecordIdentifier.dom_id(issue)} form[action=?]", answer_conversation_project_issue_path(@conversation, issue)
    assert_select "#generation_blockers h2", text: "Antes de gerar a proposta"
  end

  test "a IA registra pendência pelo chat, com card, sem duplicar" do
    tool = RegisterPendingIssueTool.new(conversation: @conversation)

    tool.execute(pergunta: "As bacias estão no escopo?", impacto: "Muda o nº de poços.")
    tool.execute(pergunta: "as bacias estão no escopo")

    assert_equal 1, @conversation.project_issues.count
    assert @conversation.messages.exists?(content: { project_issue_id: @conversation.project_issues.first.id }.to_json)
  end

  test "a IA registra a resposta dada no chat" do
    issue = @conversation.project_issues.create!(question: "As bacias estão no escopo?")

    AnswerPendingIssueTool.new(conversation: @conversation).execute(pendencia_id: issue.id, resposta: "Só as quatro do ET.")

    assert_equal "Só as quatro do ET.", issue.reload.answer
  end

  test "o resumo extrai as pendências bloqueantes e abre um card pra cada" do
    @conversation.update!(processing_steps: @conversation.processing_steps.merge("summary" => "queued"))
    json = { pendencias: [ { pergunta: "As 2.994 diárias batem com a escala 14×14?", impacto: "Muda a equipe." } ] }.to_json

    stub_ai_complete([ "# RESUMO", json ]) { GenerateSummaryJob.perform_now(@conversation.id) }

    issue = @conversation.project_issues.sole
    assert_equal "As 2.994 diárias batem com a escala 14×14?", issue.question
    assert_equal "resumo", issue.source
    assert @conversation.messages.exists?(content: { project_issue_id: issue.id }.to_json)
  end
end
