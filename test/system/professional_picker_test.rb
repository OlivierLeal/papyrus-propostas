require "application_system_test_case"

# Busca de profissional na Tela de Precificação (2026-09, pedido do consultor: "algo mais
# esperto pra puxar os funcionários" — o <select> simples virou uma lista longa demais de
# rolar). Ver app/javascript/controllers/professional_picker_controller.js.
class ProfessionalPickerTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
  end

  test "buscar por especialidade filtra a lista, e clicar num resultado preenche o campo escondido" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: "Fauna"
    assert_selector "li button", text: professionals(:biologa).name

    click_button professionals(:biologa).name

    assert_field "proposal_professional[professional_id]", type: :hidden, with: professionals(:biologa).id.to_s
    assert_text professionals(:biologa).role
  end

  test "adicionar uma linha pelo campo de busca cria o profissional escolhido na equipe" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: professionals(:biologa).name
    click_button professionals(:biologa).name
    fill_in "proposal_professional[deliverable_name]", with: "Diagnóstico de Fauna"
    click_button "Adicionar à equipe"

    assert_text "adicionado(a) à equipe"
    assert_field with: "Diagnóstico de Fauna"
  end

  # Relato do consultor (2026-09): "seleciono a pessoa e não consigo adicionar". Com a escolha no
  # click, o blur do campo (já no mousedown) apagava a lista antes de um clique humano "lento"
  # terminar — ninguém ficava selecionado. Aqui o clique é segurado de propósito.
  test "clique lento num resultado ainda seleciona a pessoa e libera o botão" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    assert_button "Adicionar à equipe", disabled: true
    fill_in "Buscar por nome, cargo ou especialidade...", with: "Beth"
    result = find("li button", text: professionals(:biologa).name)
    page.driver.browser.action.click_and_hold(result.native).pause(duration: 0.4).release.perform

    assert_field "proposal_professional[professional_id]", type: :hidden, with: professionals(:biologa).id.to_s
    assert_button "Adicionar à equipe", disabled: false
  end

  test "Enter na busca escolhe o primeiro resultado sem salvar o preço" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: "Beth"
    assert_selector "li button", text: professionals(:biologa).name
    find("input[placeholder='Buscar por nome, cargo ou especialidade...']").send_keys(:enter)

    assert_field "proposal_professional[professional_id]", type: :hidden, with: professionals(:biologa).id.to_s
    assert_no_text "Preço recalculado"
  end

  test "equipe fixa não tem botão de remover" do
    line = project_pricings(:priced_pricing).proposal_professionals.create!(
      professional: professionals(:diretora), deliverable_name: "Direção de Negócios", man_hours: 0, field_days: 0
    )
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    within("tr", text: professionals(:diretora).name) do
      assert_text "Fixo"
      assert_no_selector "a[title='Remover da equipe']"
    end
    within("tr", text: professionals(:biologa).name) { assert_selector "a[title='Remover da equipe']" }
    assert line.persisted?
  end

  test "remover um membro não fixo pela tela" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    accept_confirm do
      within("tr", text: professionals(:biologa).name) { find("a[title='Remover da equipe']").click }
    end

    assert_text "Linha removida."
    assert_no_selector "tr", text: professionals(:biologa).name
  end

  test "adicionar item de cronograma pelo rodapé da tabela" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "add-schedule-servico-activity", with: "Campanha de campo"
    fill_in "add-schedule-servico-phase", with: "Diagnóstico"
    within("tfoot", text: "Adicionar", match: :first) { click_button "Adicionar" }

    assert_text "Item do cronograma adicionado."
    assert_field with: "Campanha de campo"
  end

  private

  def sign_in
    session = @user.sessions.create!
    visit new_conversation_path
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
    visit new_conversation_path
  end
end
