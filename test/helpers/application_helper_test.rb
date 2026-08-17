require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "render_markdown converts basic markdown to sanitized HTML" do
    html = render_markdown("**Tipo de licença:** LP")

    assert_includes html, "<strong>Tipo de licença:</strong>"
  end

  test "render_markdown strips embedded raw HTML instead of rendering it (XSS protection)" do
    html = render_markdown("Texto <script>alert('x')</script> normal")

    assert_not_includes html, "<script>"
  end

  test "render_markdown adds a blank line before a list that has none, so Redcarpet renders it as a list" do
    html = render_markdown("**Diagnósticos:**\n* Fauna\n* Flora")

    assert_includes html, "<ul>"
    assert_includes html, "<li>Fauna</li>"
  end

  test "render_markdown returns an empty-safe string for nil input" do
    assert_equal "", render_markdown(nil)
  end

  test "render_markdown adds rel and target to links" do
    html = render_markdown("[INEMA](https://inema.ba.gov.br)")

    assert_includes html, 'rel="noopener noreferrer"'
    assert_includes html, 'target="_blank"'
  end

  test "flash_config returns the success config for notice and success" do
    assert_equal "success", flash_config("notice")[:color]
    assert_equal "success", flash_config("success")[:color]
  end

  test "flash_config returns the error config for alert and error" do
    assert_equal "error", flash_config("alert")[:color]
    assert_equal "error", flash_config("error")[:color]
  end

  test "flash_config returns the warning config for warning" do
    assert_equal "warning", flash_config("warning")[:color]
  end

  test "flash_config falls back to the info config for an unknown flash type" do
    assert_equal ApplicationHelper::FLASH_TYPES["info"], flash_config("qualquer_coisa_desconhecida")
  end
end
