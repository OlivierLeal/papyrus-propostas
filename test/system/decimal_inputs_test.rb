require "application_system_test_case"

# Relato do consultor (2026-09-28): distância 429,9 km (sugerida pela Mapbox) travava o "Salvar e
# recalcular" com "Selecione um valor válido. Os dois valores válidos mais próximos são 429 e 430"
# — os campos tinham step fixo, e o navegador recusa valor fora do passo.
class DecimalInputsTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
    @proposal = proposals(:priced_proposal)
  end

  test "campos decimais da precificação aceitam valor quebrado" do
    sign_in
    visit conversation_proposal_path(@proposal.conversation)
    open_pricing_tab "itens"

    find("input[name='project_pricing[distance_km]']").set("429.9")
    find("input[name='project_pricing[vehicle_consumption_km_per_liter]']").set("10.35")
    open_pricing_tab "equipe"
    line = proposal_professionals(:coordenacao_line)
    within("tr", text: line.professional.name) { find("input[name$='[man_hours]']").set("12.25") }
    click_button "Salvar e recalcular"

    assert_no_text "Selecione um valor válido"
    open_pricing_tab "itens"
    assert_selector "input[name='project_pricing[distance_km]'][value='429.9']"
    assert_equal 429.9, @proposal.project_pricing.reload.distance_km.to_f
    assert_equal 10.35, @proposal.project_pricing.vehicle_consumption_km_per_liter.to_f
    assert_equal 12.25, line.reload.man_hours.to_f
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
