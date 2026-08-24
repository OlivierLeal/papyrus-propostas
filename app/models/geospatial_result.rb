class GeospatialResult < ApplicationRecord
  belongs_to :conversation

  # Imagem da área de estudo mostrada na tela e embutida no .docx — mapa real via Mapbox Static
  # Images API (PNG) quando MAPBOX_API_KEY está configurada e a chamada funciona, ou o croqui SVG
  # simples (AreaSketchRenderer) como reserva automática (ver ProcessKmzJob).
  has_one_attached :area_image

  AREA_LABELS = { "polygon" => "Área do KMZ", "line" => "Linha do KMZ", "point" => "Pontos do KMZ" }.freeze

  # Título do card na tela de revisão (conversations/show.html.erb) — "Área do KMZ" só fazia
  # sentido pra polígono; linha/ponto usam o rótulo certo pro tipo de geometria.
  def area_label
    AREA_LABELS.fetch(geometry_type, "Área do KMZ")
  end

  # Nem todo KMZ tem polígono — linha de transmissão vira <LineString> (extensão, não área) e
  # medição eólica/ponto de amostragem vira <Point> (só localização) — ver KmzGeometryExtractor.
  def summary_text
    case geometry_type
    when "polygon"
      return "Dados geoespaciais ainda não processados." if area_ha.blank?

      "Área: #{area_ha.round(2)} ha · Perímetro: #{perimeter_km.round(2)} km"
    when "line"
      return "Dados geoespaciais ainda não processados." if length_km.blank?

      "Extensão: #{length_km.round(2)} km"
    when "point"
      "Localização pontual (sem área ou extensão calculada)."
    else
      "Dados geoespaciais ainda não processados."
    end
  end
end
