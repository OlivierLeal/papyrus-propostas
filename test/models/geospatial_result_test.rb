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
end
