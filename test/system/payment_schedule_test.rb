require "application_system_test_case"

# Desembolso editável na Tela de Precificação (2026-09-27, pedido do consultor: "o cronograma de
# desembolso tem que ser calculado e ser possível adicionar"). Ver
# app/javascript/controllers/payment_schedule_controller.js e ProjectPricing#payment_schedule_items=.
class PaymentScheduleTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
  end

  test "adicionar parcela, ver o valor calculado e salvar" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    percentages = all("input[name$='[percentage]']")
    percentages[1].fill_in(with: "50") # Protocolo 60 → 50
    click_button "Adicionar parcela"
    assert_text "Os percentuais precisam somar 100% para salvar."

    new_row = all("tr[data-payment-schedule-target='row']").last
    new_row.find("input[name$='[label]']").fill_in(with: "Entrega do relatório")
    new_row.find("input[name$='[percentage]']").fill_in(with: "10")
    assert_no_text "Os percentuais precisam somar 100% para salvar."

    click_button "Salvar e recalcular"
    assert_text "Preço recalculado."

    schedule = @proposal.project_pricing.reload.payment_schedule
    assert_equal [ 30, 50, 5, 5, 10 ], schedule.map { |item| item["percentage"] }
    assert_equal "Entrega do relatório", schedule.last["label"]
  end

  test "remover parcela" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    all("button[title='Remover parcela']")[3].click # Emissão da licença (5%)
    all("input[name$='[percentage]']").select(&:visible?)[2].fill_in(with: "10") # Vistoria 5 → 10
    click_button "Salvar e recalcular"
    assert_text "Preço recalculado."

    assert_equal [ "Assinatura do contrato", "Protocolo no órgão ambiental", "Vistoria" ],
      @proposal.project_pricing.reload.payment_schedule.map { |item| item["label"] }
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
