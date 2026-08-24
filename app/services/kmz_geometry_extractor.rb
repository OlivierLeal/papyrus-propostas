# Extrai geometria de um KMZ/KML — área/perímetro (polígono), extensão (linha) ou só a
# localização (ponto), sem depender de nenhuma base de dados externa (municípios/biomas/UCs ficam
# de fora por decisão, ver CLAUDE.md seção 11.1 — exigiriam shapefiles reais que não temos).
#
# Nem todo projeto da Papyrus tem uma área poligonal: linha de transmissão e estudo de corredor
# viram <LineString> (extensão em km, não área), e medição eólica/pontos de amostragem viram
# <Point> (só localização, sem área nem extensão) — achado na prática num KMZ real que só tinha
# linha e ponto, sem nenhum polígono, e quebrava com NoPolygonFoundError. A prioridade quando o
# KMZ mistura tipos (raro, mas acontece) é polígono > linha > ponto — mas os outros tipos
# encontrados continuam sendo extraídos e ficam disponíveis pra desenhar no mapa/croqui, só não
# entram na métrica principal (area_ha/length_km) do tipo que não é o dominante.
#
# RGeo::Geographic.spherical_factory não implementa #area (só #length), e a gem rgeo-proj4 está
# quebrada nesta instalação (a versão do PROJ do sistema usa a API nova baseada em CRS, incompatível
# com o formato de string proj4 legado que a gem espera — RGeo::Error::InvalidProjection ao
# reprojetar). Por isso área/perímetro/extensão são calculados à mão numa projeção local
# equiretangular (válida pra escala de poucos km de um projeto ambiental — erro desprezível nessa
# escala). O RGeo só monta a geometria de verdade (pra salvar na coluna geography do PostGIS) e
# calcula o centroide do polígono, que ele faz bem no factory esférico.
class KmzGeometryExtractor
  Result = Struct.new(
    :geometry_type, :area_ha, :perimeter_km, :length_km, :centroid, :geometry,
    :local_rings, :local_lines, :local_points,
    keyword_init: true
  )

  class NoGeometryFoundError < StandardError; end

  EARTH_RADIUS_M = 6_371_000.0
  FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

  def initialize(bytes)
    @bytes = bytes
  end

  def call
    doc = parsed_kml
    rings = extract_rings(doc)
    lines = extract_lines(doc)
    points = extract_points(doc)

    raise NoGeometryFoundError, "Nenhuma geometria (polígono, linha ou ponto) encontrada no KMZ/KML." if rings.empty? && lines.empty? && points.empty?

    if rings.any?
      polygon_result(rings, lines, points)
    elsif lines.any?
      line_result(lines, points)
    else
      point_result(points)
    end
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

    def parsed_kml
      doc = Nokogiri::XML(kml_xml)
      doc.remove_namespaces! # Google Earth/QGIS/ArcGIS variam o namespace do KML; sem isso o xpath falha.
      doc
    end

    # Só contorno externo (outerBoundaryIs) — buracos (innerBoundaryIs) são ignorados nesta
    # primeira versão, não afetam a área/perímetro calculados aqui.
    def extract_rings(doc)
      doc.xpath("//Polygon/outerBoundaryIs/LinearRing/coordinates").filter_map do |node|
        points = parse_coordinates(node.text)
        close_ring(points) if points.size >= 3
      end
    end

    def extract_lines(doc)
      doc.xpath("//LineString/coordinates").filter_map do |node|
        points = parse_coordinates(node.text)
        points if points.size >= 2
      end
    end

    def extract_points(doc)
      doc.xpath("//Point/coordinates").filter_map { |node| parse_coordinates(node.text).first }
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

    def reference_point(point_groups)
      all_points = point_groups.flatten(1)
      [ all_points.sum(&:first) / all_points.size, all_points.sum(&:last) / all_points.size ]
    end

    def polygon_result(rings, lines, points)
      lon0, lat0 = reference_point(rings)
      polygons = rings.map { |ring| build_polygon(ring, lon0, lat0) }
      largest = polygons.max_by { |p| p[:area_m2] }
      total_area_m2 = polygons.sum { |p| p[:area_m2] }

      Result.new(
        geometry_type: "polygon",
        area_ha: (total_area_m2 / 10_000.0).round(4),
        perimeter_km: (polygons.sum { |p| p[:perimeter_m] } / 1_000.0).round(4),
        centroid: weighted_centroid(polygons, total_area_m2),
        geometry: largest[:geometry],
        local_rings: polygons.map { |p| p[:local_points] },
        local_lines: lines.map { |line| build_line(line, lon0, lat0)[:local_points] },
        local_points: points.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      )
    end

    def line_result(lines, points)
      lon0, lat0 = reference_point(lines)
      built = lines.map { |line| build_line(line, lon0, lat0) }
      total_length_m = built.sum { |l| l[:length_m] }
      geometry = built.size == 1 ? built.first[:geometry] : FACTORY.multi_line_string(built.map { |l| l[:geometry] })

      Result.new(
        geometry_type: "line",
        length_km: (total_length_m / 1_000.0).round(4),
        centroid: FACTORY.point(lon0, lat0),
        geometry: geometry,
        local_rings: [],
        local_lines: built.map { |l| l[:local_points] },
        local_points: points.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      )
    end

    def point_result(points)
      lon0, lat0 = reference_point([ points ])
      geometry = points.size == 1 ? FACTORY.point(*points.first) : FACTORY.multi_point(points.map { |lon, lat| FACTORY.point(lon, lat) })

      Result.new(
        geometry_type: "point",
        centroid: FACTORY.point(lon0, lat0),
        geometry: geometry,
        local_rings: [],
        local_lines: [],
        local_points: points.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      )
    end

    def build_polygon(ring, lon0, lat0)
      local_points = ring.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      geometry = FACTORY.polygon(FACTORY.linear_ring(ring.map { |lon, lat| FACTORY.point(lon, lat) }))

      { geometry: geometry, local_points: local_points, area_m2: shoelace_area(local_points), perimeter_m: perimeter(local_points) }
    end

    def build_line(line, lon0, lat0)
      local_points = line.map { |lon, lat| to_local_xy(lon, lat, lon0, lat0) }
      geometry = FACTORY.line_string(line.map { |lon, lat| FACTORY.point(lon, lat) })

      { geometry: geometry, local_points: local_points, length_m: perimeter(local_points) }
    end

    # Projeção equiretangular local (plano tangente centrado na geometria) — suficiente pra
    # calcular área/perímetro/extensão com precisão nessa escala, sem depender de reprojeção via
    # PROJ4.
    def to_local_xy(lon, lat, lon0, lat0)
      x = (lon - lon0) * Math.cos(lat0 * Math::PI / 180) * EARTH_RADIUS_M * Math::PI / 180
      y = (lat - lat0) * EARTH_RADIUS_M * Math::PI / 180
      [ x, y ]
    end

    def shoelace_area(points)
      points.each_cons(2).sum { |(x1, y1), (x2, y2)| (x1 * y2) - (x2 * y1) }.abs / 2.0
    end

    # Some os segmentos consecutivos — funciona tanto pro perímetro de um anel fechado (polígono)
    # quanto pra extensão de uma linha aberta, já que os dois são só sequências de pontos.
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
