require "application_system_test_case"

# O indicador de "digitando" aparecia ACIMA da mensagem recém-enviada pelo consultor, e voltava
# ao lugar certo com F5 — ou seja, o banco estava certo e o DOM não. Este teste trava a ordem
# visual, que é a única coisa que o consultor enxerga.
class ChatMessageOrderTest < ApplicationSystemTestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @user = users(:one)
  end

  test "segunda mensagem enviada com o indicador já na tela mantém a ordem" do
    sign_in
    visit conversation_path(@conversation)

    fill_in "content", with: "primeira pergunta"
    click_on "Enviar"
    assert_selector "#typing_indicator", wait: 10

    # O consultor manda outra antes de a IA responder — o indicador da primeira ainda está lá.
    fill_in "content", with: "segunda pergunta"
    click_on "Enviar"
    assert_text "segunda pergunta", wait: 10
    sleep 1

    ordem = dom_order
    puts "\nordem com duas mensagens:"
    ordem.each_with_index { |item, i| puts "  #{i + 1}. #{item}" }

    typing = ordem.rindex("TYPING")
    segunda = ordem.rindex { |item| item.include?("segunda pergunta") }

    assert_equal 1, ordem.count("TYPING"), "não pode sobrar indicador duplicado"
    assert_operator segunda, :<, typing, "o indicador tem que vir DEPOIS da última mensagem"
  end

  test "mensagem enviada aparece acima do indicador de digitando" do
    sign_in

    visit conversation_path(@conversation)
    fill_in "content", with: "gere a proposta tecnica"
    click_on "Enviar"

    assert_selector "#typing_indicator", wait: 10

    # É isto que acontece de verdade enquanto a IA responde: o job atualiza a conversa
    # (ex.: ensure_proposal! muda o status para "pricing") e o broadcasts_refreshes do
    # Conversation manda um refresh, que o layout aplica como MORPH da página inteira.
    @conversation.update!(status: "pricing")
    sleep 1.5

    ordem = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#messages > div')).map(
        el => el.id === 'typing_indicator' ? 'TYPING' : el.innerText.slice(0, 40).replace(/\\s+/g, ' ')
      )
    JS

    puts "\nordem no DOM:"
    ordem.each_with_index { |item, i| puts "  #{i + 1}. #{item}" }

    typing = ordem.index("TYPING")
    mensagem = ordem.rindex { |item| item.include?("gere a proposta") }

    assert mensagem, "a mensagem enviada precisa estar no DOM"
    assert typing, "o indicador precisa estar no DOM"
    assert_operator mensagem, :<, typing, "o indicador tem que vir DEPOIS da mensagem enviada"

    # A ordem visual acima é garantida pelo order-last do indicador. Esta checagem cobre a
    # causa raiz: os dois elementos vêm num broadcast só, então também chegam ao DOM em ordem.
    # Sem ela, o teste continuaria verde mesmo se os broadcasts voltassem a ser separados.
    assert_operator dom_index("gere a proposta"), :<, dom_index("TYPING"),
      "mensagem e indicador precisam chegar ao DOM na ordem certa, não só parecer ordenados"
  end

  private

  # Posição no DOM, sem o desempate visual do order-last.
  def dom_index(needle)
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#messages > div')).findIndex(
        el => (el.id === 'typing_indicator' ? 'TYPING' : el.innerText).includes(#{needle.to_json})
      )
    JS
  end

  # Ordem VISUAL (posição na tela), não a do DOM: é o que o consultor enxerga, e o indicador
  # usa order-last, então as duas podem divergir legitimamente.
  def dom_order
    page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#messages > div'))
        .map(el => ({
          y: el.getBoundingClientRect().top,
          label: el.id === 'typing_indicator' ? 'TYPING' : el.innerText.slice(0, 40).replace(/\s+/g, ' ')
        }))
        .sort((a, b) => a.y - b.y)
        .map(item => item.label)
    JS
  end

  # Autentica pelo cookie de sessão, como o SessionTestHelper faz nos testes de integração —
  # passar pelo formulário aqui só adicionaria um ponto de falha alheio ao que se quer testar.
  def sign_in
    session = @user.sessions.create!
    visit conversation_path(@conversation)

    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
  end
end
