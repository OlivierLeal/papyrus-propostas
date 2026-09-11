require "application_system_test_case"

# Achado ao vivo (2026-09, relato do consultor): escolher arquivos de uma pasta, e depois
# escolher MAIS arquivos de outra pasta no MESMO campo, apagava a seleção anterior — o diálogo
# nativo do navegador troca input.files pela escolha nova sozinho; sem compensar isso no JS
# (file_list_controller#update), a segunda rodada de escolha vencia a primeira. Ver
# app/javascript/controllers/file_list_controller.js.
class FileListAccumulationTest < ApplicationSystemTestCase
  setup do
    @user = users(:one)
  end

  test "escolher arquivos duas vezes no mesmo campo acumula em vez de substituir" do
    sign_in

    field = find("input[name='complementary_documents[]']", visible: :all)
    field.set(Rails.root.join("test/fixtures/files/tr_sample.pdf").to_s)
    assert_selector "span.badge", text: "tr_sample.pdf"

    field.set(Rails.root.join("test/fixtures/files/comp_sample.pdf").to_s)

    assert_selector "span.badge", text: "tr_sample.pdf"
    assert_selector "span.badge", text: "comp_sample.pdf"
    assert_equal 2, all("span.badge").size
  end

  test "remover um chip mantém os outros arquivos escolhidos em rodadas diferentes" do
    sign_in

    field = find("input[name='complementary_documents[]']", visible: :all)
    field.set(Rails.root.join("test/fixtures/files/tr_sample.pdf").to_s)
    field.set(Rails.root.join("test/fixtures/files/comp_sample.pdf").to_s)
    assert_equal 2, all("span.badge").size

    within("span.badge", text: "tr_sample.pdf") { find("button").click }

    assert_no_selector "span.badge", text: "tr_sample.pdf"
    assert_selector "span.badge", text: "comp_sample.pdf"
    assert_equal 1, all("span.badge").size
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
