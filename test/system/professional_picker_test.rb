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
    click_button "Adicionar linha"

    assert_selector "td", text: "Diagnóstico de Fauna"
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
