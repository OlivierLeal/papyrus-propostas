require "application_system_test_case"

# Tela de Precificação em abas (2026-10, remodelagem: "a tela ficou complicada, muita informação").
# As abas só escondem partes do MESMO #pricing-form — o que foi digitado numa aba vai junto ao
# salvar de outra —, a aba escolhida volta depois do redirect, e a âncora de "+ Campo" abre a aba
# e o campo certos.
class PricingTabsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
    @pricing = @proposal.project_pricing
  end

  test "pendência leva à aba dela; campo digitado em outra aba vai junto ao salvar; a aba volta depois do redirect" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    assert_selector "[role='tab'][data-tab='equipe'][aria-selected='true']"

    find("button[data-tab='cronograma']", text: "Sem cronograma").click
    assert_selector "[role='tab'][data-tab='cronograma'][aria-selected='true']"
    assert_field "add-schedule-servico-activity"

    open_pricing_tab "itens"
    find("input[name='project_pricing[distance_km]']").set("321")
    open_pricing_tab "equipe"
    within("tr", text: proposal_professionals(:coordenacao_line).professional.name) { find("input[name$='[man_hours]']").set("12") }
    click_button "Salvar e recalcular"

    assert_text "Preço recalculado"
    assert_selector "[role='tab'][data-tab='equipe'][aria-selected='true']"
    assert_equal 321, @pricing.reload.distance_km.to_f
    assert_equal 12, proposal_professionals(:coordenacao_line).reload.man_hours.to_f
  end

  test "+ Campo volta pra aba Itens e campo com o campo novo aberto" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    open_pricing_tab "itens"
    click_button "+ Campo"

    assert_selector "[role='tab'][data-tab='itens'][aria-selected='true']"
    new_campaign = @pricing.reload.pricing_items.flat_map(&:field_campaigns).max_by(&:id)
    assert_selector "details#campo-#{new_campaign.id}[open]"
  end

  test "adicionar à equipe num item novo, sem sair da aba Equipe" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)

    fill_in "Buscar por nome, cargo ou especialidade...", with: professionals(:biologa).name
    click_button professionals(:biologa).name
    fill_in "proposal_professional[deliverable_name]", with: "Relatório de fauna"
    assert_no_field "member_new_item_name"
    select "+ Novo item…", from: "proposal_professional[pricing_item_id]"
    fill_in "member_new_item_name", with: "Relatórios"
    click_button "Adicionar à equipe"

    assert_text "adicionado(a) à equipe"
    assert_selector "[role='tab'][data-tab='equipe'][aria-selected='true']"
    assert_selector "tbody", text: "Relatórios"
    assert_equal "Relatórios", @pricing.reload.proposal_professionals.find_by!(deliverable_name: "Relatório de fauna").pricing_item.name
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
