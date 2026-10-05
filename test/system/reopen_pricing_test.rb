require "application_system_test_case"

# Reabrir precificação aprovada (2026-09-27, pedido do consultor: o cliente às vezes pede mudança
# depois do preço aprovado). Ver Proposal#reopen!.
class ReopenPricingTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
    @proposal.approve!
  end

  test "reabrir a proposta aprovada com motivo e voltar a editar" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    assert_text "Aprovado em"
    assert_no_button "Salvar e recalcular"

    find("summary", text: "Reabrir para ajuste").click
    fill_in "reason", with: "Cliente pediu incluir campanha de fauna"
    accept_confirm { click_button "Reabrir precificação" }

    assert_text "Precificação reaberta"
    assert_text "Motivo: Cliente pediu incluir campanha de fauna"
    assert_button "Salvar e recalcular"
    assert_selector "input[name$='[man_hours]']:not([disabled])", minimum: 1
    assert_equal "priced", @proposal.reload.status
  end

  private

  def sign_in
    session = @user.sessions.create!
    visit new_conversation_path
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
    page.driver.browser.manage.window.resize_to(1500, 900)
    visit new_conversation_path
  end
end
