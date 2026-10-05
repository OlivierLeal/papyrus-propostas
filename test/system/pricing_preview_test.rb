require "application_system_test_case"

# Prévia ao vivo da Tela de Precificação (2026-09-27, pedido do consultor: mudar a hora-homem e
# ver o valor mudar na hora). Ver app/javascript/controllers/pricing_preview_controller.js.
class PricingPreviewTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
    @line = proposal_professionals(:coordenacao_line) # 40 HH × R$ 250 = R$ 10.000,00 de custo (× 1,5 no preço)
  end

  test "mudar horas-homem atualiza subtotal, total da equipe e total da proposta na hora, sem salvar" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    total_before = find("[data-pricing-preview-target='summaryTotal']").text
    assert_no_text "Prévia · não salvo"

    within("tr", text: @line.professional.name) do
      find("input[name$='[man_hours]']").fill_in(with: "10")
      assert_selector "[data-role='subtotal']", text: "R$ 2.500,00" # custo puro: 10 × 250
    end

    assert_text "Prévia · não salvo"
    assert_selector "[data-pricing-preview-target='teamTotal']", text: "R$ 21.340,00" # custo puro: 2.500 + 18.840
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

    # A linha mostra o custo puro (40 × 250 + 2 × 350 = 10.700,00); o BDI = 1 zera a linha "+ BDI" do resumo.
    within("tr", text: @line.professional.name) { assert_selector "[data-role='subtotal']", text: "R$ 10.700,00" }
    assert_selector "[data-pricing-preview-target='summaryBdi']", text: "R$ 0,00"
    assert_equal find("[data-pricing-preview-target='summaryTotal']").text, find("[data-pricing-preview-target='compositionTotal']").text
  end

  # 2026-09-28: logística por campo, dentro do item, × BDI × impostos (FieldCampaign#breakdown).
  test "mudar um campo atualiza o custo dele, o item, a logística e o total — igual ao que o servidor grava" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    open_pricing_tab "itens"

    campaign_row = find("[data-pricing-preview-target='campaign']")
    within(campaign_row) do
      find("input[data-field='people']").fill_in(with: "2")      # + alimentação 1 × 2 dias × 80
      find("select[data-field='vehicle_type']").select("4x4")    # diária 4x4: 750 (em vez de 150)
    end
    # custo direto: veículo 2 × 750 = 1.500 + combustível 400 + alimentação 2 × 2 × 80 = 320
    # + hospedagem 0 + pedágios 240 = 2.460 → × 1,5 = 3.690,00
    within(campaign_row) { assert_selector "[data-role='campaign-total']", text: "R$ 2.460,00" } # custo puro (× 1,5 = 3.690)
    assert_selector "[data-pricing-preview-target='logistics']", text: "R$ 2.460,00"
    assert_selector "[data-pricing-preview-target='summaryTotal']", text: "R$ 46.950,00" # 43.260 + 3.690
    preview_total = find("[data-pricing-preview-target='summaryTotal']").text

    click_button "Salvar e recalcular"
    preview_composition = %w[summaryDirect summaryBdi summaryTaxes].map { |t| find("[data-pricing-preview-target='#{t}']").text }
    assert_text "Preço recalculado"
    assert_equal preview_total, find("[data-pricing-preview-target='summaryTotal']").text
    # Composição (custo direto + BDI + impostos) da prévia bate com a do servidor.
    assert_equal preview_composition, %w[summaryDirect summaryBdi summaryTaxes].map { |t| find("[data-pricing-preview-target='#{t}']").text }
    assert_equal 46_950, @proposal.project_pricing.reload.total_value
  end

  # 2026-09-29: hospedagem a 2h por trecho da área → 4h úteis → o campo de 2 dias vira 4, e a
  # bióloga (48 diárias no item) ganha +48. A prévia tem que bater com o que o servidor grava.
  test "deslocamento até a hospedagem alonga o campo e as diárias da equipe, igual ao servidor" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    open_pricing_tab "itens"

    campaign_row = find("[data-pricing-preview-target='campaign']")
    within(campaign_row) do
      find("select[data-field='lodging_mode']").select("Fornecida pelo cliente")
      find("input[data-field='commute_km']").fill_in(with: "90")
      find("input[data-field='commute_hours']").fill_in(with: "2")
      assert_selector "[data-role='commute-note']", text: "2 → 4 dias em campo"
    end
    open_pricing_tab "equipe"
    within("tr", text: proposal_professionals(:fauna_flora_line).professional.name) do
      assert_selector "[data-role='commute-extra']", text: "+48 desloc."
    end
    preview_total = find("[data-pricing-preview-target='summaryTotal']").text

    click_button "Salvar e recalcular"
    assert_text "Preço recalculado"
    assert_equal preview_total, find("[data-pricing-preview-target='summaryTotal']").text
    assert_equal 48, proposal_professionals(:fauna_flora_line).reload.commute_extra_days
  end

  # 2026-09-30: item espelhado da planilha do cliente — a linha tem esforço POR UNIDADE e o total é
  # por-unidade × quantidade do cliente. A prévia tem que bater com o que o servidor grava.
  test "esforço por unidade num item espelhado: prévia = por unidade × quantidade, igual ao servidor" do
    pricing = @proposal.project_pricing
    item = pricing.pricing_items.create!(name: "Diária embarcada", position: 5, client_quantity: 100, client_unit: "diária", client_code: "1.1")
    line = pricing.proposal_professionals.create!(professional: @line.professional, deliverable_name: "Observador", pricing_item: item,
                                                  man_hours: 0, field_days: 0, field_days_per_unit: 0.5)
    pricing.recalculate!
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    within(find("input[name$='[field_days_per_unit]']").ancestor("tr")) do
      find("input[name$='[field_days_per_unit]']").fill_in(with: "0.25")
      assert_selector "[data-role='per-unit-days']", text: "total 25"
      assert_selector "[data-role='subtotal']", text: "R$ 8.750,00" # 25 diárias × R$ 350
    end
    preview_total = find("[data-pricing-preview-target='summaryTotal']").text

    click_button "Salvar e recalcular"
    assert_text "Preço recalculado"
    assert_equal preview_total, find("[data-pricing-preview-target='summaryTotal']").text
    assert_equal 25, line.reload.field_days
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
