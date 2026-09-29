require "test_helper"

# Enquadramento pela legislação × o que o cliente pediu (pedido da Sara, 2026-09-29): "a
# legislação diz isso, o cliente diz isso, faço o quê?" — seguir a lei, seguir o pedido ou levar
# ao cliente decidir, e a proposta registra as duas versões em qualquer caso.
class LegalFramingTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @conversation.study_types.clear
    @requested = @conversation.project_findings.create!(field: "tipo_estudo", value: "rap", nature: "fato", source_kind: "tr")
    @legal = @conversation.project_findings.create!(field: "tipo_estudo", value: "eia_rima", nature: "fato", source_kind: "cal",
      locator: "NL7484 — Resolução 4636/18 (CAL/Ius Natura)")
    @conflict = @conversation.project_conflicts.create!(field: "tipo_estudo", summary: "A lei exige EIA-RIMA; o TR pede RAP.")
    [ @requested, @legal ].each { |f| @conflict.project_conflict_findings.create!(project_finding: f) }
  end

  test "o estudo exigido pela legislação não vira estudo da proposta sozinho" do
    @conversation.assign_study_types_from_findings!

    assert_equal [ study_types(:rap) ], @conversation.reload.study_types
  end

  test "divergência entre CAL e pedido sobre licença/estudo é de enquadramento; outras não" do
    assert @conflict.legal_framing?

    area = @conversation.project_conflicts.create!(field: "area_ha", summary: "x")
    assert_not area.legal_framing?
  end

  test "seguir a legislação troca o estudo da proposta pelo que a lei exige" do
    @conversation.study_types << study_types(:rap)

    @conflict.resolve!(users(:one), value: "eia_rima")

    assert_equal [ study_types(:eia_rima) ], @conversation.reload.study_types
  end

  test "levar ao cliente não decide nem supera nada, e ainda dá pra decidir depois" do
    @conflict.refer_to_client!(users(:one))

    assert @conflict.client?
    assert @conflict.undecided?
    assert_equal %w[active active], [ @requested.reload.status, @legal.reload.status ]
  end

  test "o estado da proposta manda escrever o enquadramento legal e o solicitado, conforme a decisão" do
    @conflict.refer_to_client!(users(:one))

    @conversation.refresh_proposal_state_snapshot!
    text = @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last.content

    assert_includes text, "[ENQUADRAMENTO LEGAL × O QUE FOI SOLICITADO]"
    assert_includes text, "legislação diz eia_rima (NL7484"
    assert_includes text, "foi solicitado rap (Termo de Referência)"
    assert_includes text, "LEVAR AO CLIENTE"
    # Não repete no bloco genérico de divergências abertas.
    assert_not_includes text, "[DIVERGÊNCIAS ABERTAS ENTRE OS DOCUMENTOS]"
  end

  test "depois de decidido, a proposta continua registrando as duas versões" do
    @conflict.resolve!(users(:one), value: "rap")

    @conversation.refresh_proposal_state_snapshot!
    text = @conversation.messages.where(role: "user", internal: true).where("content LIKE ?", "[ESTADO ATUAL DA PROPOSTA]%").last.content

    assert_includes text, "o consultor decidiu: a proposta contempla rap"
    assert_includes text, "legislação diz eia_rima"
  end

  test "o resumo abre um tópico de enquadramento com o que a lei diz e o que foi pedido" do
    text = GenerateSummaryJob.new.send(:legal_framing_summary, @conversation)

    assert_includes text, "ENQUADRAMENTO LEGAL × O QUE FOI SOLICITADO"
    assert_includes text, "[#{@legal.citation_code}]"
    assert_includes text, "[#{@requested.citation_code}]"
    assert_includes text, "levar ao"
  end

  test "sem enquadramento pelo CAL, o resumo avisa que o pedido não foi conferido" do
    @conflict.destroy!
    @legal.destroy!

    text = GenerateSummaryJob.new.send(:legal_framing_summary, @conversation)

    assert_includes text, "NÃO foi conferido contra a legislação"
  end
end
