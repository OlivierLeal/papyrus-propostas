# Busca uma imagem estática de verdade (satélite + ruas) do polígono da área de estudo via
# Mapbox Static Images API — usa o mesmo objeto de geometria que KmzGeometryExtractor já monta,
# não recalcula nada. Chave em ENV["MAPBOX_API_KEY"] (nunca hardcoded, configuração opcional —
# ver CLAUDE.md seção 12). Sem chave, erro de rede ou resposta ruim, devolve nil em vez de
# levantar — quem chama (ProcessKmzJob) cai pro croqui SVG local nesse caso.
class MapboxStaticMap
  STYLE = "mapbox/satellite-streets-v12".freeze
  WIDTH = 800
  HEIGHT = 600
  STROKE_COLOR = "#0284c7".freeze
  FILL_COLOR = "#0ea5e9".freeze

  def self.available?
    ENV["MAPBOX_API_KEY"].present?
  end

  def initialize(polygon)
    @polygon = polygon
  end

  def fetch
    return nil unless self.class.available?

    uri = URI(url)
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    response.body
  rescue StandardError => e
    Rails.logger.error("MapboxStaticMap failed: #{e.class} #{e.message}")
    nil
  end

  private
    # Sem o sufixo de formato, a Static Images API devolve JPEG por padrão (confirmado num teste
    # manual — o resto do pipeline, do ProcessKmzJob ao GenerateProposalDocumentTool, assume PNG
    # pelo content_type pra decidir se embute a imagem no .docx).
    def url
      "https://api.mapbox.com/styles/v1/#{STYLE}/static/geojson(#{encoded_geojson})/auto/#{WIDTH}x#{HEIGHT}.png?access_token=#{ENV['MAPBOX_API_KEY']}"
    end

    # simplestyle-spec — a Static Images API já sabe desenhar essas propriedades por cima do mapa.
    def encoded_geojson
      coordinates = @polygon.exterior_ring.points.map { |point| [ point.x, point.y ] }
      geojson = {
        type: "Feature",
        geometry: { type: "Polygon", coordinates: [ coordinates ] },
        properties: { stroke: STROKE_COLOR, "stroke-width": 3, fill: FILL_COLOR, "fill-opacity": 0.25 }
      }
      ERB::Util.url_encode(geojson.to_json)
    end
end
