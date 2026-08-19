# Croqui simples (SVG) do(s) polígono(s) do KMZ — sem mapa de fundo, já que ainda não há chave
# do Mapbox configurada (ver CLAUDE.md seção 3). Recebe as coordenadas já em metros locais (mesmo
# referencial usado pelo cálculo de área/perímetro em KmzGeometryExtractor#local_rings), então as
# posições relativas entre polígonos batem. Sem dependência externa — SVG é texto puro, o
# navegador renderiza nativamente via <img>.
class PolygonSketchRenderer
  VIEWBOX_SIZE = 600
  MARGIN = 30

  def initialize(local_rings)
    @local_rings = local_rings
  end

  def call
    points = @local_rings.flatten(1)
    min_x, max_x = points.map(&:first).minmax
    min_y, max_y = points.map(&:last).minmax
    scale = (VIEWBOX_SIZE - (2 * MARGIN)) / [ max_x - min_x, max_y - min_y, 1.0 ].max

    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{VIEWBOX_SIZE} #{VIEWBOX_SIZE}">
        <rect width="100%" height="100%" fill="#f8fafc" />
        #{@local_rings.map { |ring| polygon_tag(ring, min_x, min_y, scale) }.join}
      </svg>
    SVG
  end

  private
    def polygon_tag(ring, min_x, min_y, scale)
      points = ring.map { |x, y| "#{svg_x(x, min_x, scale)},#{svg_y(y, min_y, scale)}" }.join(" ")
      %(<polygon points="#{points}" fill="#0ea5e9" fill-opacity="0.15" stroke="#0284c7" stroke-width="2" />)
    end

    def svg_x(x, min_x, scale)
      ((x - min_x) * scale) + MARGIN
    end

    # SVG cresce pra baixo, coordenada geográfica cresce pra cima — inverte o eixo.
    def svg_y(y, min_y, scale)
      VIEWBOX_SIZE - (((y - min_y) * scale) + MARGIN)
    end
end
