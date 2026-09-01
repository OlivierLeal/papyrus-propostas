require "test_helper"

class AiJsonResponseTest < ActiveSupport::TestCase
  test "parses plain JSON" do
    assert_equal({ "a" => 1 }, AiJsonResponse.parse('{"a": 1}'))
  end

  test "strips ```json ... ``` fences before parsing" do
    text = "```json\n{\"a\": 1}\n```"
    assert_equal({ "a" => 1 }, AiJsonResponse.parse(text))
  end

  test "strips plain ``` fences (no json language tag) before parsing" do
    text = "```\n{\"a\": 1}\n```"
    assert_equal({ "a" => 1 }, AiJsonResponse.parse(text))
  end

  test "returns nil for blank input" do
    assert_nil AiJsonResponse.parse(nil)
    assert_nil AiJsonResponse.parse("")
  end

  test "returns nil for text that isn't valid JSON even after stripping fences" do
    assert_nil AiJsonResponse.parse("isso não é json de jeito nenhum")
  end

  # REGRESSÃO — achado ao vivo (ProcessLegalNormsJob, pesquisa real no CAL): depois de usar uma
  # ferramenta algumas vezes, a IA às vezes narra um resumo antes do bloco ```json, mesmo o
  # prompt pedindo pra não fazer isso. Um achado real de 7 itens (texto de norma incluído) se
  # perdeu em silêncio por causa disso antes desta correção.
  test "strips fences that aren't at the very start of the string, with narration before them" do
    text = "Com base na pesquisa, identifiquei o seguinte:\n\n```json\n{\"a\": 1}\n```"
    assert_equal({ "a" => 1 }, AiJsonResponse.parse(text))
  end

  test "parses nested JSON with narration before the fence, without stopping at the first inner '}'" do
    text = "Segue a análise:\n\n```json\n{\"achados\": [{\"campo\": \"x\"}, {\"campo\": \"y\"}]}\n```"
    result = AiJsonResponse.parse(text)
    assert_equal 2, result["achados"].size
  end

  test "falls back to the first '{' through the last '}' when there's no fence at all" do
    text = "Aqui está o resultado: {\"a\": 1} — espero que ajude."
    assert_equal({ "a" => 1 }, AiJsonResponse.parse(text))
  end
end
