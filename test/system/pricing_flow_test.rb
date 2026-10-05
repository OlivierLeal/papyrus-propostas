require "application_system_test_case"

# Fluxo completo da Tela de Precificação, na ordem em que o consultor trabalha (2026-10): itens →
# equipe → campo → custos → cronograma → pagamento → aprovar. Cada etapa confere o que foi gravado.
class PricingFlowTest < ApplicationSystemTestCase
  SHOTS = ENV["PRICING_SCREENSHOTS"]

  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
  end

  test "fluxo completo: item → equipe → campo → custos → cronograma → pagamento → aprovar" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    shot "01_inicio"

    # 1. Item novo já com nome, sem sair da aba Equipe (a 1ª etapa). Enter cria o item.
    fill_in "team_new_item_name", with: "Diagnóstico de Fauna"
    find_field("team_new_item_name").send_keys(:enter)
    assert_selector "tbody", text: "Diagnóstico de Fauna"
    assert_selector "[role='tab'][data-tab='equipe'][aria-selected='true']"
    item = @pricing.reload.pricing_items.order(:position).last
    assert_equal "Diagnóstico de Fauna", item.name
    assert_text "Ninguém neste item ainda"
    shot "02_item_criado"

    # 2. Equipe no item novo.
    fill_in "Buscar por nome, cargo ou especialidade...", with: professionals(:biologa).name
    click_button professionals(:biologa).name
    fill_in "proposal_professional[deliverable_name]", with: "Diagnóstico de fauna terrestre"
    select "Diagnóstico de Fauna", from: "proposal_professional[pricing_item_id]"
    fill_in "proposal_professional[man_hours]", with: "40"
    fill_in "proposal_professional[field_days]", with: "10"
    click_button "Adicionar à equipe"
    assert_text "adicionado(a) à equipe"
    line = @pricing.reload.proposal_professionals.find_by!(deliverable_name: "Diagnóstico de fauna terrestre")
    assert_equal item, line.pricing_item
    shot "03_equipe"

    # 3. Campo no item novo.
    open_pricing_tab "itens"
    within("#item-#{item.id}") { click_button "+ Campo" }
    assert_selector "#item-#{item.id} [data-pricing-preview-target='campaign']"
    campaign = item.reload.field_campaigns.last
    within("#campo-#{campaign.id}") do
      find("input[name$='[description]']").set("Campanha de fauna")
      find("input[data-field='people']").set("1")
      find("input[data-field='days']").set("10")
      find("select[data-field='lodging_mode']").select("Alojamento, casa alugada ou outro")
      find("input[name$='[lodging_name]']").set("Casa na vila")
      find("input[data-field='lodging_price_per_night']").set("120")
    end
    within("#item-#{item.id}") { click_button "+ Custo" }
    assert_field with: "Novo custo"
    within("#item-#{item.id}") do
      find("input[name$='[description]'][value='Novo custo']").set("Licença de captura")
      all("input[data-field='unit_value']").last.set("850")
    end
    save_pricing
    campaign.reload
    assert_equal [ "Campanha de fauna", 10, "alojamento" ], [ campaign.description, campaign.days.to_i, campaign.lodging_mode ]
    assert_equal "Licença de captura", item.reload.costs.last["description"]
    # Diárias × dias de campo: o item novo bate (10 = 1 pessoa × 10 dias); o da fixture, não.
    assert_no_text "Diagnóstico de Fauna: "
    assert_text "Execução do serviço: 48 diárias na equipe"
    shot "04_campo_e_custos"

    # 4. Custo externo.
    open_pricing_tab "custos"
    within("section", text: "Custos externos", match: :first) do
      fill_in "description", with: "Taxa do órgão"
      fill_in "value", with: "1500"
      click_button "Adicionar"
    end
    assert_text "Custo adicionado"
    assert_selector "[role='tab'][data-tab='custos'][aria-selected='true']"
    shot "05_custos_externos"

    # 5. Cronograma.
    open_pricing_tab "cronograma"
    fill_in "add-schedule-servico-phase", with: "Diagnóstico"
    fill_in "add-schedule-servico-activity", with: "Campanha de fauna"
    within("tfoot", text: "Adicionar", match: :first) { click_button "Adicionar" }
    assert_field with: "Campanha de fauna", wait: 5
    assert_selector "[role='tab'][data-tab='cronograma'][aria-selected='true']"
    assert_equal 1, @pricing.schedule_items.count
    shot "06_cronograma"

    # 6. Pagamento: preço aberto por item.
    open_pricing_tab "pagamento"
    find("input[name='project_pricing[price_presentation]'][value='itens']").click
    assert_button "Aprovar preço", disabled: true # alteração não salva
    save_pricing
    assert_equal "itens", @pricing.reload.price_presentation
    shot "07_pagamento"

    # 7. Total = soma das partes, e aprovar.
    expected = @pricing.reload.total_value
    assert_selector "[data-pricing-preview-target='summaryTotal']", text: ActiveSupport::NumberHelper.number_to_currency(expected, unit: "R$", separator: ",", delimiter: ".")
    accept_confirm { click_button "Aprovar preço" }
    assert_text "Preço aprovado"
    assert_equal "approved", @proposal.reload.status
    shot "08_aprovado"
  end

  private

  # Depois de salvar a página recarrega sem alteração pendente, e "Aprovar" volta a valer (o aviso
  # "Preço recalculado" some sozinho, não serve de espera).
  def save_pricing
    assert_button "Aprovar preço", disabled: true
    click_button "Salvar e recalcular"
    assert_button "Aprovar preço", disabled: false
  end

  def shot(name)
    save_screenshot(File.join(SHOTS, "#{name}.png")) if SHOTS
  end

  def sign_in
    session = @user.sessions.create!
    visit new_conversation_path
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
    visit new_conversation_path
  end
end
