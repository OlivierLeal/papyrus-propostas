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

  def label
    "#{name}/#{uf}"
  end

  # "Remanso/BA", "Remanso - BA", "Remanso, BA", "Petrópolis (RJ) — texto solto" ou só "Remanso"
  # (quando o nome é único no país). Sem diferenciar acento nem caixa. Nome repetido sem UF é
  # ambíguo → nil.
  def self.lookup(text)
    text = text.to_s.strip
    match = text.match(/\A(.+?)\s*[\/,\-–]\s*([A-Za-z]{2})\z/) || text.match(/\A([^(]+?)\s*\(([A-Za-z]{2})\)/)
    name, uf = match ? [ match[1], match[2].upcase ] : [ text, nil ]
    key = normalize(name)
    scope = uf ? where(uf: uf) : all
    found = scope.pluck(:id, :name).select { |_id, candidate| normalize(candidate) == key }
    found.size == 1 ? find(found.first.first) : nil
  end

  def self.normalize(name)
    I18n.transliterate(name.to_s).downcase.gsub(/[^a-z0-9]+/, " ").strip
  end

  # Municípios cujo centro está entre min_km e max_km de um ponto, do mais perto pro mais longe —
  # Lodging::Search usa pra buscar hospedagem além do raio máximo da Stay22 (~100 km).
  def self.nearest_centroids(point, min_km:, max_km:, limit:)
    sql_point = "ST_SetSRID(ST_MakePoint(#{point.x.to_f}, #{point.y.to_f}), 4326)::geography"
    distance = "ST_Distance(ST_Centroid(geom::geometry)::geography, #{sql_point})"
    where("ST_DWithin(geom, #{sql_point}, ?)", max_km * 1000)
      .where("#{distance} >= ?", min_km * 1000)
      .order(Arel.sql(distance))
      .limit(limit)
      .pluck(:name, :uf, Arel.sql("ST_X(ST_Centroid(geom::geometry))"), Arel.sql("ST_Y(ST_Centroid(geom::geometry))"), Arel.sql(distance))
      .map { |name, uf, lon, lat, meters| { label: "#{name}/#{uf}", point: KmzGeometryExtractor::FACTORY.point(lon, lat), km: meters / 1000.0 } }
  end
end
