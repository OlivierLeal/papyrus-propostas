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
end
