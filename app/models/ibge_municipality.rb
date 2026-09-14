# Camada de referência (CLAUDE.md seção 3/11.1) — só município, das 6 camadas planejadas.
# Populado por script/geospatial/import_ibge_municipalities.rb, nunca por seed manual (5.570
# municípios). Só leitura pelo app; o único escritor é o script de import (upsert por code_ibge).
class IbgeMunicipality < ApplicationRecord
  validates :code_ibge, presence: true, uniqueness: true
  validates :name, presence: true
  validates :uf, presence: true, length: { is: 2 }

  # ProcessKmzJob usa isso pra achar em quais municípios um polígono/linha/ponto de KMZ cai.
  # ST_Intersects (não ST_Contains) de propósito: um KMZ de linha de transmissão pode atravessar
  # a fronteira entre dois municípios sem estar inteiramente CONTIDO em nenhum dos dois.
  scope :intersecting, ->(geometry) { where("ST_Intersects(geom, ?)", geometry) }

  # Centroide do município, como ponto RGeo (mesma factory esférica de KmzGeometryExtractor) —
  # usado por Logistics::DestinationResolver quando não há centroide de KMZ (fallback só pelo
  # município identificado). Primeira consulta ST_Centroid sobre esta tabela (só tinha
  # ST_Intersects até aqui).
  def centroid
    # geom é geography — ST_X/ST_Y só aceitam geometry, daí o cast explícito.
    lon, lat = self.class.where(id: id)
      .pick(Arel.sql("ST_X(ST_Centroid(geom::geometry))"), Arel.sql("ST_Y(ST_Centroid(geom::geometry))"))
    return nil unless lon && lat

    KmzGeometryExtractor::FACTORY.point(lon, lat)
  end
end
