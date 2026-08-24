require "test_helper"

class GeospatialResultTest < ActiveSupport::TestCase
  test "summary_text says data isn't processed yet when area_ha is blank" do
    result = GeospatialResult.new(conversation: conversations(:reviewing_conversation))

    assert_equal "Dados geoespaciais ainda não processados.", result.summary_text
  end

  test "summary_text formats area and perimeter once they are set" do
    result = GeospatialResult.new(conversation: conversations(:reviewing_conversation), area_ha: 123.456, perimeter_km: 7.891)

    assert_equal "Área: 123.46 ha · Perímetro: 7.89 km", result.summary_text
  end

  # Nem todo KMZ tem polígono — linha de transmissão vira geometry_type "line" (extensão, não
  # área) e ponto de medição vira "point" (só localização) — ver KmzGeometryExtractor.
  test "summary_text formats the length in km when geometry_type is 'line'" do
    result = GeospatialResult.new(conversation: conversations(:reviewing_conversation), geometry_type: "line", length_km: 12.345)

    assert_equal "Extensão: 12.35 km", result.summary_text
  end

  test "summary_text says data isn't processed yet when geometry_type is 'line' but length_km is blank" do
    result = GeospatialResult.new(conversation: conversations(:reviewing_conversation), geometry_type: "line")

    assert_equal "Dados geoespaciais ainda não processados.", result.summary_text
  end

  test "summary_text describes a point location without area or length" do
    result = GeospatialResult.new(conversation: conversations(:reviewing_conversation), geometry_type: "point")

    assert_equal "Localização pontual (sem área ou extensão calculada).", result.summary_text
  end

  test "area_label matches the geometry_type so the review screen card title makes sense" do
    conversation = conversations(:reviewing_conversation)

    assert_equal "Área do KMZ", GeospatialResult.new(conversation: conversation, geometry_type: "polygon").area_label
    assert_equal "Linha do KMZ", GeospatialResult.new(conversation: conversation, geometry_type: "line").area_label
    assert_equal "Pontos do KMZ", GeospatialResult.new(conversation: conversation, geometry_type: "point").area_label
  end

  test "area_image_src returns nil when there is no image attached" do
    result = GeospatialResult.create!(conversation: conversations(:reviewing_conversation), geometry_type: "polygon")

    assert_nil result.area_image_src
  end

  test "area_image_src serves the Mapbox PNG through Active Storage" do
    result = GeospatialResult.create!(conversation: conversations(:reviewing_conversation), geometry_type: "polygon")
    result.area_image.attach(io: StringIO.new("png-bytes"), filename: "mapa.png", content_type: "image/png")

    assert_equal result.area_image, result.area_image_src
  end

  # O Active Storage serve image/svg+xml como application/octet-stream com disposition attachment,
  # e a <img> não renderiza nada — o croqui de reserva precisa ir embutido.
  test "area_image_src embeds the SVG sketch as a data URI instead of an Active Storage URL" do
    svg = %(<svg xmlns="http://www.w3.org/2000/svg"></svg>)
    result = GeospatialResult.create!(conversation: conversations(:reviewing_conversation), geometry_type: "polygon")
    result.area_image.attach(io: StringIO.new(svg), filename: "croqui.svg", content_type: "image/svg+xml")

    src = result.area_image_src

    assert src.start_with?("data:image/svg+xml;base64,")
    assert_equal svg, Base64.decode64(src.delete_prefix("data:image/svg+xml;base64,"))
  end
end
