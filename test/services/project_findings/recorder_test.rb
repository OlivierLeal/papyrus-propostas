require "test_helper"

class ProjectFindings::RecorderTest < ActiveSupport::TestCase
  setup do
    @conversation = conversations(:processing_conversation)
    @recorder = ProjectFindings::Recorder.new(@conversation, source_kind: "tr")
  end

  test "records a finding with its field, value, nature and evidence" do
    finding = @recorder.call("achados" => [ {
      "campo" => "orgao_ambiental", "valor" => "INEMA", "natureza" => "fato",
      "trecho" => "...protocolo junto ao INEMA...", "local" => "item 2.1"
    } ]).sole

    assert_equal "orgao_ambiental", finding.field
    assert_equal "INEMA", finding.value
    assert_equal "fato", finding.nature
    assert_equal "tr", finding.source_kind
    assert_equal "item 2.1", finding.locator
    assert_equal "active", finding.status
  end

  # Chave fora do menu não pode entrar como está (não agrupa nem compara com nada), mas descartar
  # perderia informação que o consultor ainda quer ver.
  test "a field outside the closed menu falls back to 'outro' keeping the original label" do
    finding = @recorder.call("achados" => [ {
      "campo" => "prazo_de_vistoria", "valor" => "30 dias", "natureza" => "fato"
    } ]).sole

    assert_equal "outro", finding.field
    assert_equal "prazo de vistoria: 30 dias", finding.value
  end

  # Na dúvida sobre a procedência, tratar como dedução é o erro barato; tratar como lido no
  # documento é o caro.
  test "an unknown nature becomes inferencia, never fato" do
    finding = @recorder.call("achados" => [ {
      "campo" => "tipo_licenca", "valor" => "LP", "natureza" => "certeza absoluta"
    } ]).sole

    assert_equal "inferencia", finding.nature
  end

  test "truncates the excerpt so one verbose reply can't bloat the record" do
    finding = @recorder.call("achados" => [ {
      "campo" => "tipo_licenca", "valor" => "LP", "natureza" => "fato", "trecho" => "x" * 900
    } ]).sole

    assert_equal ProjectFinding::EXCERPT_LIMIT, finding.excerpt.length
  end

  test "skips malformed entries instead of losing the whole extraction" do
    findings = @recorder.call("achados" => [
      { "campo" => "tipo_licenca", "valor" => "" },
      "isso não é um achado",
      { "campo" => "tipo_licenca", "valor" => "LP", "natureza" => "fato" }
    ])

    assert_equal [ "LP" ], findings.map(&:value)
  end

  test "records nothing when the AI reply had no parsable payload" do
    assert_empty @recorder.call(nil)
  end
end
