require "application_system_test_case"

# Campo único "Horas" na Tela de Precificação (2026-09, pedido do consultor: "não precisa de
# campo de horas escritório e horas campo, é o mesmo valor" — na digitação manual ele sempre
# preenchia os dois com o mesmo número). Ver app/javascript/controllers/hours_sync_controller.js.
# O motor de cálculo continua recebendo os dois campos separados por baixo (rate_office/
# rate_field continuam diferentes por profissional) — só a entrada manual foi consolidada.
class HoursSyncTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
  end

  test "editar o campo Horas de uma linha existente grava o mesmo valor em escritório e campo" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    line = proposal_professionals(:coordenacao_line)
    within("tr", text: line.deliverable_name) do
      find("[data-hours-sync-target='visible']").set("15")
    end
    click_button "Recalcular preço"
    within("tr", text: line.deliverable_name) { assert_text "R$ 13.500,00" } # espera o redirect antes de consultar o banco

    assert_equal 15.0, line.reload.hours_office
    assert_equal 15.0, line.hours_field
  end

  test "adicionar linha pelo campo Horas preenche escritório e campo com o mesmo valor" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: professionals(:biologa).name
    click_button professionals(:biologa).name
    fill_in "proposal_professional[deliverable_name]", with: "Diagnóstico extra"
    within("form[action$='proposal_professionals']") do
      find("[data-hours-sync-target='visible']").set("22")
    end
    click_button "Adicionar linha"
    assert_selector "td", text: "Diagnóstico extra" # espera o redirect/reload antes de consultar o banco

    line = @proposal.project_pricing.proposal_professionals.find_by!(deliverable_name: "Diagnóstico extra")
    assert_equal 22.0, line.hours_office
    assert_equal 22.0, line.hours_field
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
