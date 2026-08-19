# Extrai geometria de um KMZ/KML — área, perímetro e centroide do polígono da área de estudo,
# sem depender de nenhuma base de dados externa (municípios/biomas/UCs ficam de fora por decisão,
# ver CLAUDE.md seção 11.1 — exigiriam shapefiles reais que não temos).
#
# RGeo::Geographic.spherical_factory não implementa #area (só #length), e a gem rgeo-proj4 está
# quebrada nesta instalação (a versão do PROJ do sistema usa a API nova baseada em CRS, incompatível
# com o formato de string proj4 legado que a gem espera — RGeo::Error::InvalidProjection ao
# reprojetar). Por isso área/perímetro são calculados à mão numa projeção local equiretangular
# (válida pra escala de poucos km de um projeto ambiental — erro desprezível nessa escala). O RGeo
# só monta a geometria de verdade (pra salvar nas colunas geography do PostGIS) e calcula o
# centroide, que ele faz bem no factory esférico.
class KmzGeometryExtractor
  Result = Struct.new(:area_ha, :perimeter_km, :centroid, :polygon, :local_rings, keyword_init: true)

  class NoPolygonFoundError < StandardError; end

  EARTH_RADIUS_M = 6_371_000.0
  FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

  def initialize(bytes)
    @bytes = bytes
  end

  def call
    rings = extract_rings(kml_xml)
    raise NoPolygonFoundError, "Nenhum polígono encontrado no KMZ/KML." if rings.empty?

    lon0, lat0 = reference_point(rings)
    polygons = rings.map { |ring| build_polygon(ring, lon0, lat0) }
    largest = polygons.max_by { |p| p[:area_m2] }
    total_area_m2 = polygons.sum { |p| p[:area_m2] }

    Result.new(
      area_ha: (total_area_m2 / 10_000.0).round(4),
      perimeter_km: (polygons.sum { |p| p[:perimeter_m] } / 1_000.0).round(4),
      centroid: weighted_centroid(polygons, total_area_m2),
      polygon: largest[:geometry],
      local_rings: polygons.map { |p| p[:local_points] }
    )
  end

  private
    # KMZ é um zip com um .kml dentro (nome não é sempre "doc.kml"); mas o controller também
    # aceita a extensão .kml crua, então cai aqui direto se não for um zip válido.
    def kml_xml
      Zip::File.open_buffer(@bytes) do |zip|
        entry = zip.glob("**/*.kml").first
        return entry.get_input_stream.read.force_encoding("UTF-8") if entry
      end
      @bytes.to_s.dup.force_encoding("UTF-8")
    rescue StandardError
      @bytes.to_s.dup.force_encoding("UTF-8")
    end

    # Só contorno externo (outerBoundaryIs) — buracos (innerBoundaryIs) são ignorados nesta
    # primeira versão, não afetam a área/perímetro calculados aqui.
    def extract_rings(xml)
      doc = Nokogiri::XML(xml)
      doc.remove_namespaces! # Google Earth/QGIS/ArcGIS variam o namespace do KML; sem isso o xpath falha.

      doc.xpath("//Polygon/outerBoundaryIs/LinearRing/coordinates").filter_map do |node|
        points = parse_coordinates(node.text)
        close_ring(points) if points.size >= 3
      end
    end

    def parse_coordinates(text)
      text.strip.split(/\s+/).filter_map do |triplet|
        lon, lat, = triplet.split(",").map(&:to_f)
        [ lon, lat ] if lon && lat
      end
    end

    def close_ring(points)
      points.first == points.last ? points : points + [ points.first ]
    end

    def reference_point(rings)
      all_points = rings.flatten(1)
      [ all_points.sum(&:first) / all_points.size, all_points.sum(&:last) / all_points.size ]
    end

    def build_polygon(ring, lon0, lat0)
      local_points = ring.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      geometry = FACTORY.polygon(FACTORY.linear_ring(ring.map { |lon, lat| FACTORY.point(lon, lat) }))

      { geometry: geometry, local_points: local_points, area_m2: shoelace_area(local_points), perimeter_m: perimeter(local_points) }
    end

    # Projeção equiretangular local (plano tangente centrado no polígono) — suficiente pra
    # calcular área/perímetro com precisão nessa escala, sem depender de reprojeção via PROJ4.
    def to_local_xy(lon, lat, lon0, lat0)
      x = (lon - lon0) * Math.cos(lat0 * Math::PI / 180) * EARTH_RADIUS_M * Math::PI / 180
      y = (lat - lat0) * EARTH_RADIUS_M * Math::PI / 180
      [ x, y ]
    end

    def shoelace_area(points)
      points.each_cons(2).sum { |(x1, y1), (x2, y2)| (x1 * y2) - (x2 * y1) }.abs / 2.0
    end

    def perimeter(points)
      points.each_cons(2).sum { |(x1, y1), (x2, y2)| Math.hypot(x2 - x1, y2 - y1) }
    end

    # Múltiplos polígonos no KMZ (raro, mas acontece — ex.: área principal + acessos): o
    # centroide final é a média dos centroides de cada um, ponderada pela área — não é o
    # centroide exato da união, mas é uma aproximação razoável sem precisar de GEOS pra unir.
    def weighted_centroid(polygons, total_area_m2)
      return polygons.first[:geometry].centroid if total_area_m2.zero?

      lon = polygons.sum { |p| p[:geometry].centroid.x * p[:area_m2] } / total_area_m2
      lat = polygons.sum { |p| p[:geometry].centroid.y * p[:area_m2] } / total_area_m2
      FACTORY.point(lon, lat)
    end
end
