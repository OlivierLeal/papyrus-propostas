class GeospatialResult < ApplicationRecord
  belongs_to :conversation

  # Imagem da área de estudo mostrada na tela e embutida no .docx — mapa real via Mapbox Static
  # Images API (PNG) quando MAPBOX_API_KEY está configurada e a chamada funciona, ou o croqui SVG
  # simples (PolygonSketchRenderer) como reserva automática (ver ProcessKmzJob).
  has_one_attached :area_image

  def summary_text
    return "Dados geoespaciais ainda não processados." if area_ha.blank?

    "Área: #{area_ha.round(2)} ha · Perímetro: #{perimeter_km.round(2)} km"
  end
end
