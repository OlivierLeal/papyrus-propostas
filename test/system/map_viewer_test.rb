require "application_system_test_case"

class MapViewerTest < ApplicationSystemTestCase
  setup do
    @conversation = conversations(:reviewing_conversation)
    @user = users(:one)
    attach_map
  end

  test "abre o mapa ampliado e fecha com ESC" do
    sign_in
    visit conversation_path(@conversation)

    assert_no_selector "dialog[open]"

    find("button[title='Ampliar mapa da área de estudo']").click
    assert_selector "dialog[open]", wait: 5

    # O mapa ampliado precisa ser sensivelmente maior que a miniatura da barra lateral —
    # é o motivo de existir do botão.
    miniatura, ampliado = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('img[alt="Mapa da área de estudo"]'))
        .map(img => img.getBoundingClientRect().width)
    JS
    assert_operator ampliado, :>, miniatura * 1.5, "o mapa ampliado ficou do mesmo tamanho"

    info = page.evaluate_script(<<~JS)
      (() => {
        const dlg = document.querySelector('dialog[open]');
        const box = dlg.querySelector('.modal-box');
        const img = box.querySelector('img');
        const r = box.getBoundingClientRect();
        const ir = img.getBoundingClientRect();
        return { topLayer: dlg.matches(':modal'), boxW: Math.round(r.width), boxH: Math.round(r.height),
                 imgW: Math.round(ir.width), imgH: Math.round(ir.height),
                 vw: window.innerWidth, vh: window.innerHeight,
                 centered: Math.abs((r.left + r.right) / 2 - window.innerWidth / 2) < 5 };
      })()
    JS
    puts "\nmodal: #{info.inspect}"
    assert info["topLayer"], "o dialog precisa estar em modo modal (top layer)"
    assert info["centered"], "o modal precisa estar centralizado"
    assert_operator info["imgH"], :<=, info["vh"], "a imagem não pode ultrapassar a altura da tela"

    find("body").send_keys :escape
    assert_no_selector "dialog[open]", wait: 5
  end

  private

  def attach_map
    result = @conversation.geospatial_result || @conversation.create_geospatial_result!(area_ha: 10, perimeter_km: 2)
    return if result.area_image.attached?

    result.area_image.attach(
      io: Rails.root.join("test/fixtures/files/mapa_area.png").open,
      filename: "mapa_area.png",
      content_type: "image/png"
    )
  end

  def sign_in
    session = @user.sessions.create!
    visit conversation_path(@conversation)
    jar = ActionDispatch::TestRequest.create.cookie_jar
    jar.signed[:session_id] = session.id
    page.driver.browser.manage.add_cookie(name: "session_id", value: jar[:session_id])
  end
end
