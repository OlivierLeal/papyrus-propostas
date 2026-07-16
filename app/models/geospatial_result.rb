class GeospatialResult < ApplicationRecord
  belongs_to :conversation

  def summary_text
    return "Dados geoespaciais ainda não processados." if area_ha.blank?

    "Área: #{area_ha.round(2)} ha · Perímetro: #{perimeter_km.round(2)} km"
  end
end
