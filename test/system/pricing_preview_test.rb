require "application_system_test_case"

# Prévia ao vivo da Tela de Precificação (2026-09-27, pedido do consultor: mudar a hora-homem e
# ver o valor mudar na hora). Ver app/javascript/controllers/pricing_preview_controller.js.
class PricingPreviewTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
    @line = proposal_professionals(:coordenacao_line) # 40 HH × R$ 250 × 1,20 × 1,25 = R$ 15.000,00
  end

  test "mudar horas-homem atualiza subtotal, total da equipe e total da proposta na hora, sem salvar" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    total_before = find("[data-pricing-preview-target='summaryTotal']").text
    assert_no_text "Prévia · não salvo"

    within("tr", text: @line.professional.name) do
      find("input[name$='[man_hours]']").fill_in(with: "10")
      assert_selector "[data-role='subtotal']", text: "R$ 3.750,00" # 10 × 250 × 1,5
    end

    assert_text "Prévia · não salvo"
    assert_selector "[data-pricing-preview-target='teamTotal']", text: "R$ 32.010,00" # 3.750 + 28.260
    assert_no_selector "[data-pricing-preview-target='summaryTotal']", text: total_before
    assert_equal 15_000, @line.reload.subtotal, "prévia não grava nada"
  end

  test "diárias e BDI também entram na prévia" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    within("tr", text: @line.professional.name) do
      find("input[name$='[field_days]']").fill_in(with: "2") # + 2 × R$ 350
    end
    find("input[name='project_pricing[bdi]']").fill_in(with: "1")

    # (40 × 250 + 2 × 350) × 1,00 × 1,25 = 13.375,00
    within("tr", text: @line.professional.name) { assert_selector "[data-role='subtotal']", text: "R$ 13.375,00" }
  end

  # 2026-09-28: logística por campo, dentro do item, × BDI × impostos (FieldCampaign#breakdown).
  test "mudar um campo atualiza o custo dele, o item, a logística e o total — igual ao que o servidor grava" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    campaign_row = find("[data-pricing-preview-target='campaign']")
    within(campaign_row) do
      find("input[data-field='people']").fill_in(with: "2")      # + alimentação 1 × 2 dias × 80
      find("select[data-field='vehicle_type']").select("4x4")    # diária 4x4: 750 (em vez de 150)
    end
    # custo direto: veículo 2 × 750 = 1.500 + combustível 400 + alimentação 2 × 2 × 80 = 320
    # + hospedagem 0 + pedágios 240 = 2.460 → × 1,5 = 3.690,00
    within(campaign_row) { assert_selector "[data-role='campaign-total']", text: "R$ 3.690,00" }
    assert_selector "[data-pricing-preview-target='logistics']", text: "R$ 3.690,00"
    assert_selector "[data-pricing-preview-target='summaryTotal']", text: "R$ 46.950,00" # 43.260 + 3.690
    preview_total = find("[data-pricing-preview-target='summaryTotal']").text

    click_button "Salvar e recalcular"
    assert_text "Preço recalculado"
    assert_equal preview_total, find("[data-pricing-preview-target='summaryTotal']").text
    assert_equal 46_950, @proposal.project_pricing.reload.total_value
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
