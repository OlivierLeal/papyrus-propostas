# Croqui simples (SVG) da geometria do KMZ — polígono (preenchido), linha (traço) e/ou ponto
# (marcador), sem mapa de fundo, como reserva automática quando o Mapbox não está disponível (ver
# CLAUDE.md seção 3 e MapboxStaticMap). Recebe as coordenadas já em metros locais (mesmo
# referencial usado pelo cálculo de área/perímetro/extensão em KmzGeometryExtractor), então as
# posições relativas entre formas batem. Sem dependência externa — SVG é texto puro, o navegador
# renderiza nativamente via <img>.
class AreaSketchRenderer
  VIEWBOX_SIZE = 600
  MARGIN = 30
  POINT_RADIUS = 6

  def initialize(local_rings: [], local_lines: [], local_points: [])
    @local_rings = local_rings
    @local_lines = local_lines
    @local_points = local_points
  end

  def call
    all_points = @local_rings.flatten(1) + @local_lines.flatten(1) + @local_points
    min_x, max_x = all_points.map(&:first).minmax
    min_y, max_y = all_points.map(&:last).minmax
    scale = (VIEWBOX_SIZE - (2 * MARGIN)) / [ max_x - min_x, max_y - min_y, 1.0 ].max

    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{VIEWBOX_SIZE} #{VIEWBOX_SIZE}">
        <rect width="100%" height="100%" fill="#f8fafc" />
        #{@local_rings.map { |ring| polygon_tag(ring, min_x, min_y, scale) }.join}
        #{@local_lines.map { |line| polyline_tag(line, min_x, min_y, scale) }.join}
        #{@local_points.map { |point| point_tag(point, min_x, min_y, scale) }.join}
      </svg>
    SVG
  end

  private
    def polygon_tag(ring, min_x, min_y, scale)
      %(<polygon points="#{svg_points(ring, min_x, min_y, scale)}" fill="#0ea5e9" fill-opacity="0.15" stroke="#0284c7" stroke-width="2" />)
    end

    def polyline_tag(line, min_x, min_y, scale)
      %(<polyline points="#{svg_points(line, min_x, min_y, scale)}" fill="none" stroke="#0284c7" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />)
    end

    def point_tag(point, min_x, min_y, scale)
      x, y = point
      %(<circle cx="#{svg_x(x, min_x, scale)}" cy="#{svg_y(y, min_y, scale)}" r="#{POINT_RADIUS}" fill="#0284c7" stroke="#f8fafc" stroke-width="2" />)
    end

    def svg_points(points, min_x, min_y, scale)
      points.map { |x, y| "#{svg_x(x, min_x, scale)},#{svg_y(y, min_y, scale)}" }.join(" ")
    end

    def svg_x(x, min_x, scale)
      ((x - min_x) * scale) + MARGIN
    end

    # SVG cresce pra baixo, coordenada geográfica cresce pra cima — inverte o eixo.
    def svg_y(y, min_y, scale)
      VIEWBOX_SIZE - (((y - min_y) * scale) + MARGIN)
    end
end
