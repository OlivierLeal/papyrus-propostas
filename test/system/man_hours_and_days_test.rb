require "application_system_test_case"

# Tela de Precificação com horas-homem e diárias (2026-09, pedido do consultor: sai "hora
# escritório/hora campo", entra "hora-homem e diária"). Dois campos independentes por linha —
# subtotal = (HH × valor da hora-homem + diárias × valor da diária) × BDI × impostos.
class ManHoursAndDaysTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
  end

  test "editar horas-homem e diárias de uma linha existente recalcula o subtotal" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    line = proposal_professionals(:coordenacao_line)
    within("tr", text: line.deliverable_name) do
      find("input[name$='[man_hours]']").set("10")
      find("input[name$='[field_days]']").set("2")
    end
    click_button "Recalcular preço"
    # (10 × 250 + 2 × 350) × 1,20 × 1,25 = 4.800,00
    within("tr", text: line.deliverable_name) { assert_text "R$ 4.800,00" }

    assert_equal 10.0, line.reload.man_hours
    assert_equal 2.0, line.field_days
  end

  test "adicionar linha com horas-homem e diárias" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: professionals(:biologa).name
    click_button professionals(:biologa).name
    fill_in "proposal_professional[deliverable_name]", with: "Diagnóstico extra"
    fill_in "proposal_professional[man_hours]", with: "22"
    fill_in "proposal_professional[field_days]", with: "3"
    click_button "Adicionar linha"
    assert_selector "td", text: "Diagnóstico extra" # espera o redirect/reload antes de consultar o banco

    line = @proposal.project_pricing.proposal_professionals.find_by!(deliverable_name: "Diagnóstico extra")
    assert_equal 22.0, line.man_hours
    assert_equal 3.0, line.field_days
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
