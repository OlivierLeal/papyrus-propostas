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
end
