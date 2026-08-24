require "test_helper"

class ProjectFindings::ConflictDetectorTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
  end

  def record!(field:, value:, source_kind: "tr")
    @conversation.project_findings.create!(field: field, value: value, source_kind: source_kind, nature: "fato")
  end

  test "numeric divergence is decided by arithmetic, without calling the AI at all" do
    record!(field: "area_ha", value: "500", source_kind: "tr")
    record!(field: "area_ha", value: "620,4", source_kind: "sistema")

    conflicts = stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }

    conflict = conflicts.sole
    assert_equal "area_ha", conflict.field
    assert_includes conflict.summary, "500.0 × 620.4"
    assert_equal 2, conflict.findings.count
  end

  test "numbers within tolerance are rounding, not divergence" do
    record!(field: "area_ha", value: "500", source_kind: "tr")
    record!(field: "area_ha", value: "500,4", source_kind: "sistema")

    assert_empty stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  test "identical values never reach the AI" do
    record!(field: "orgao_ambiental", value: "INEMA", source_kind: "tr")
    record!(field: "orgao_ambiental", value: " inema ", source_kind: "complementar")

    assert_empty stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  # Duas passagens do mesmo TR falando de coisas diferentes costumam ser recortes do mesmo
  # assunto — divergência é entre FONTES.
  test "different values from the same source are not a divergence between documents" do
    record!(field: "orgao_ambiental", value: "INEMA", source_kind: "tr")
    record!(field: "orgao_ambiental", value: "IBAMA", source_kind: "tr")

    assert_empty stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  test "the AI judging two spellings as the same thing creates no conflict" do
    record!(field: "tipo_licenca", value: "LP", source_kind: "tr")
    record!(field: "tipo_licenca", value: "Licença Prévia", source_kind: "complementar")

    reply = { julgamentos: [ { indice: 0, veredito: "equivalente" } ] }.to_json
    assert_empty stub_ai_complete(reply) { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  test "the AI judging a real contradiction creates the conflict with its description" do
    record!(field: "tipo_licenca", value: "Licença Prévia", source_kind: "tr")
    record!(field: "tipo_licenca", value: "Licença de Operação", source_kind: "complementar")

    reply = { julgamentos: [ { indice: 0, veredito: "divergente", descricao: "As fases do licenciamento não batem." } ] }.to_json
    conflict = stub_ai_complete(reply) { ProjectFindings::ConflictDetector.new(@conversation).call }.sole

    assert_equal "As fases do licenciamento não batem.", conflict.summary
  end

  # Inventar divergência que não existe custa a confiança do consultor; deixar de apontar uma
  # custa uma revisão. Resposta ilegível vale como "equivalente".
  test "an unreadable AI reply is treated as equivalent, never as a divergence" do
    record!(field: "tipo_licenca", value: "LP", source_kind: "tr")
    record!(field: "tipo_licenca", value: "LO", source_kind: "complementar")

    assert_empty stub_ai_complete("desculpe, não entendi") { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  test "a field already under discussion is not raised twice" do
    record!(field: "area_ha", value: "500", source_kind: "tr")
    record!(field: "area_ha", value: "620", source_kind: "sistema")
    stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }

    assert_empty stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }
  end

  # Diagnóstico presente num documento e ausente no outro é complemento, não contradição.
  test "accumulative list fields are never compared" do
    record!(field: "diagnosticos", value: "fauna", source_kind: "tr")
    record!(field: "diagnosticos", value: "flora", source_kind: "complementar")

    assert_empty stub_ai_error { ProjectFindings::ConflictDetector.new(@conversation).call }
  end
end
