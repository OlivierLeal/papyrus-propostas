require "test_helper"

class ProjectConflictsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @conversation = conversations(:reviewing_conversation)
    @tr_finding = @conversation.project_findings.create!(
      field: "area_ha", value: "500", nature: "fato", source_kind: "tr"
    )
    @kmz_finding = @conversation.project_findings.create!(
      field: "area_ha", value: "620", nature: "fato", source_kind: "sistema"
    )
    @conflict = @conversation.project_conflicts.create!(field: "area_ha", summary: "Áreas diferentes.")
    [ @tr_finding, @kmz_finding ].each { |f| @conflict.project_conflict_findings.create!(project_finding: f) }
    sign_in_as users(:one)
  end

  # A decisão do consultor vira um achado novo, com a fonte mais forte que existe — em vez de
  # editar o que o documento disse, que apagaria o rastro da divergência.
  test "resolver registra a decisão do consultor como um achado novo" do
    post resolve_conversation_project_conflict_path(@conversation, @conflict), params: { value: "620" }

    @conflict.reload
    assert @conflict.resolved?
    assert_equal users(:one), @conflict.resolved_by

    decision = @conversation.project_findings.active.find_by(source_kind: "consultor")
    assert_equal "620", decision.value
    assert_equal "fato", decision.nature
  end

  test "os valores divergentes ficam superados, mas continuam no banco para auditoria" do
    post resolve_conversation_project_conflict_path(@conversation, @conflict), params: { value: "620" }

    decision = @conversation.project_findings.active.find_by(source_kind: "consultor")
    [ @tr_finding, @kmz_finding ].each do |finding|
      assert_equal "superseded", finding.reload.status
      assert_equal decision, finding.superseded_by
    end
  end

  test "o consultor pode escrever um valor que não é nenhum dos dois" do
    post resolve_conversation_project_conflict_path(@conversation, @conflict), params: { value: "588,3" }

    assert_equal "588,3", @conversation.project_findings.active.find_by(source_kind: "consultor").value
  end

  test "resolver sem valor não decide nada" do
    post resolve_conversation_project_conflict_path(@conversation, @conflict), params: { value: "  " }

    assert @conflict.reload.open?
    assert_nil @conversation.project_findings.find_by(source_kind: "consultor")
  end

  # "Não é divergência": os dois valores continuam válidos, nada é superado — só paramos de perguntar.
  test "descartar encerra a pergunta sem superar nenhum achado" do
    post dismiss_conversation_project_conflict_path(@conversation, @conflict)

    assert_equal "dismissed", @conflict.reload.status
    assert_equal "active", @tr_finding.reload.status
    assert_equal "active", @kmz_finding.reload.status
  end

  test "não dá para mexer na divergência de uma conversa de outro consultor" do
    sign_in_as users(:two)

    post dismiss_conversation_project_conflict_path(@conversation, @conflict)

    assert_response :not_found
    assert @conflict.reload.open?
  end

  # O card é a única forma de o consultor ver a divergência: ele nasce de uma mensagem do
  # assistente que carrega só o id (ver GenerateSummaryJob#announce_conflicts).
  test "o card da divergência aparece no chat da proposta" do
    @conversation.messages.create!(role: "assistant", content: { project_conflict_id: @conflict.id }.to_json)

    get conversation_path(@conversation)

    assert_response :success
    assert_select "##{ActionView::RecordIdentifier.dom_id(@conflict)}"
    assert_select "form[action=?]", resolve_conversation_project_conflict_path(@conversation, @conflict)
  end
end
