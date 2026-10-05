require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]

  # Tela de Precificação em abas (2026-10): equipe, itens, custos, cronograma, pagamento.
  def open_pricing_tab(key)
    find("[role='tab'][data-tab='#{key}']").click
  end
end
