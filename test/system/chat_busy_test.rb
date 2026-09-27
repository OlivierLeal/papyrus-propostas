require "application_system_test_case"

# Um turno da IA por vez (2026-09-27, cenário do consultor: pedir a proposta técnica e, enquanto
# gera, mandar outra mensagem pedindo de novo). Ver AiResponding e chat_composer_controller.js.
class ChatBusyTest < ApplicationSystemTestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
  end

  test "enquanto a IA responde dá pra escrever mas não enviar; quando ela termina, destrava" do
    @conversation.update_column(:ai_responding_since, Time.current)
    sign_in
    visit conversation_path(@conversation)

    assert_selector "#typing_indicator"
    assert_button "Aguarde...", disabled: true
    find("textarea[name='content']").fill_in(with: "gera de novo")
    find("textarea[name='content']").send_keys(:enter)
    assert_no_text "gera de novo", wait: 0.5 # Enter não enviou
    assert_field "content", with: "gera de novo" # o texto continua na caixa

    page.execute_script("document.getElementById('typing_indicator').remove()")

    assert_button "Enviar", disabled: false
    assert_field "content", with: "gera de novo"
  end

  private

  def sign_in
    session = users(:one).sessions.create!
    visit new_conversation_path
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
    visit new_conversation_path
  end
end
