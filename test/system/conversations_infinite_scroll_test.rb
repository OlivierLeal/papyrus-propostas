require "application_system_test_case"

# Scroll infinito na Tela de Propostas (2026-10): o frame lazy do fim da lista (conversations/_page)
# só busca a próxima página quando entra na tela. Isto prova o comportamento no navegador de
# verdade — o teste de controller só vê o HTML do frame, não o carregamento.
class ConversationsInfiniteScrollTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    Conversation.destroy_all
    total = ConversationsController::PER_PAGE * 2 + 3
    total.times do |i|
      Conversation.create!(user: @user, client_name: "Cliente Rolagem #{format('%03d', i)}", status: "setup")
        .update_column(:created_at, Time.current - i.minutes)
    end
    @total = total
  end

  test "rolar até o fim carrega as páginas seguintes, sem repetir o título do ano, e o card abre fora do frame" do
    sign_in

    assert_selector "a.card", count: ConversationsController::PER_PAGE
    assert_text "#{@total} propostas"

    scroll_to_end
    assert_selector "a.card", count: ConversationsController::PER_PAGE * 2, wait: 5
    scroll_to_end
    assert_selector "a.card", count: @total, wait: 5
    assert_no_selector "turbo-frame[loading=lazy] .loading", wait: 1
    assert_selector "h2", text: Date.current.year.to_s, count: 1

    find("a.card", text: "Cliente Rolagem #{format('%03d', @total - 1)}").click
    assert_current_path %r{/conversations/\d+\z}
  end

  private
    # A tela rola dentro do container do layout (shared/_layout, overflow-auto), não na janela.
    def scroll_to_end
      page.execute_script("document.querySelector('a.card:last-of-type')?.closest('.overflow-auto')?.scrollTo(0, 1e9)")
    end

    def sign_in
      session = @user.sessions.create!
      visit conversations_path
      jar = ActionDispatch::TestRequest.create.cookie_jar
      jar.signed[:session_id] = session.id
      page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
      visit conversations_path
    end
end
