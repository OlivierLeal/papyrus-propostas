class GeospatialResult < ApplicationRecord
  belongs_to :conversation

  # Croqui simples do polígono (sem mapa de fundo — sem chave do Mapbox ainda, ver CLAUDE.md
  # seção 3). Separado de `map_image_url`, que fica reservado pra quando houver mapa de verdade.
  has_one_attached :sketch_image

  def summary_text
    return "Dados geoespaciais ainda não processados." if area_ha.blank?

    "Área: #{area_ha.round(2)} ha · Perímetro: #{perimeter_km.round(2)} km"
  end
end
