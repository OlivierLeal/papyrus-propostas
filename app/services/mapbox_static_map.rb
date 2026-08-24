# Busca uma imagem estática de verdade (satélite + ruas) da geometria da área de estudo via
# Mapbox Static Images API — usa o mesmo objeto de geometria que KmzGeometryExtractor já monta
# (Polygon, LineString/MultiLineString ou Point/MultiPoint, conforme o KMZ), não recalcula nada.
# Chave em ENV["MAPBOX_API_KEY"] (nunca hardcoded, configuração opcional — ver CLAUDE.md seção
# 12). Sem chave, erro de rede ou resposta ruim, devolve nil em vez de levantar — quem chama
# (ProcessKmzJob) cai pro croqui SVG local nesse caso.
class MapboxStaticMap
  STYLE = "mapbox/satellite-streets-v12".freeze
  WIDTH = 800
  HEIGHT = 600
  STROKE_COLOR = "#0284c7".freeze
  FILL_COLOR = "#0ea5e9".freeze

  # A Static Images API recusa a requisição com 414 acima deste tamanho de URL, e o overlay
  # GeoJSON vai inteiro dentro dela. Um KMZ real chega com centenas de vértices em precisão de
  # ponto flutuante cheia — a poligonal do BESS Serra da Babilônia, com 172 pontos, gerava 8.677
  # caracteres e voltava 414, caindo silenciosamente pro croqui SVG.
  MAX_URL_LENGTH = 8192

  # ~11 cm no equador. Muito além do que 800x600 pixels conseguem mostrar, e corta a URL quase
  # pela metade (os mesmos 172 pontos passam a caber em 5.939 caracteres).
  COORD_PRECISION = 6

  # Se nem arredondado couber, ralear os vértices: um contorno com menos detalhe é melhor que
  # nenhum mapa. Acima disso a forma começa a distorcer e é melhor devolver nil.
  MAX_STRIDE = 8

  def self.available?
    ENV["MAPBOX_API_KEY"].present?
  end

  def initialize(geometry)
    @geometry = geometry
  end

  def fetch
    return nil unless self.class.available?

    target = url
    if target.nil?
      Rails.logger.error("MapboxStaticMap: geometria não cabe na URL nem com os vértices raleados")
      return nil
    end

    response = Net::HTTP.get_response(URI(target))
    unless response.is_a?(Net::HTTPSuccess)
      # Sem isto o 414 não deixava rastro nenhum: fetch devolvia nil, o ProcessKmzJob caía pro
      # croqui e o log ficava limpo.
      Rails.logger.error("MapboxStaticMap: HTTP #{response.code} (URL com #{target.length} caracteres)")
      return nil
    end

    response.body
  rescue StandardError => e
    Rails.logger.error("MapboxStaticMap failed: #{e.class} #{e.message}")
    nil
  end

  private
    # Sem o sufixo de formato, a Static Images API devolve JPEG por padrão (confirmado num teste
    # manual — o resto do pipeline, do ProcessKmzJob ao GenerateProposalDocumentTool, assume PNG
    # pelo content_type pra decidir se embute a imagem no .docx).
    #
    # Vai raleando os vértices até a URL caber em MAX_URL_LENGTH; nil quando nem no limite couber.
    def url
      (1..MAX_STRIDE).each do |stride|
        candidate = "https://api.mapbox.com/styles/v1/#{STYLE}/static/geojson(#{encoded_geojson(stride)})" \
                    "/auto/#{WIDTH}x#{HEIGHT}.png?access_token=#{ENV['MAPBOX_API_KEY']}"
        return candidate if candidate.length <= MAX_URL_LENGTH
      end

      nil
    end

    def encoded_geojson(stride)
      geojson = { type: "Feature", geometry: geojson_geometry(stride), properties: geojson_properties }
      ERB::Util.url_encode(geojson.to_json)
    end

    # KmzGeometryExtractor pode entregar Polygon (área), LineString/MultiLineString (linha de
    # transmissão, corredor) ou Point/MultiPoint (torre de medição, ponto de amostragem) —
    # dispatch pelo tipo real da geometria RGeo, sem assumir mais que é sempre um polígono.
    def geojson_geometry(stride)
      case @geometry
      when RGeo::Feature::Polygon
        { type: "Polygon", coordinates: [ trimmed(@geometry.exterior_ring.points, stride) ] }
      when RGeo::Feature::MultiLineString
        { type: "MultiLineString", coordinates: @geometry.map { |line| trimmed(line.points, stride) } }
      when RGeo::Feature::LineString
        { type: "LineString", coordinates: trimmed(@geometry.points, stride) }
      when RGeo::Feature::MultiPoint
        { type: "MultiPoint", coordinates: @geometry.map { |point| rounded(point) } }
      else
        { type: "Point", coordinates: rounded(@geometry) }
      end
    end

    # Mantém 1 vértice a cada `stride` e sempre o último — num anel de polígono o último ponto
    # repete o primeiro, e é ele que fecha a figura; perdê-lo geraria um anel aberto.
    def trimmed(points, stride)
      kept = stride > 1 ? points.each_slice(stride).map(&:first) : points.to_a
      kept << points.last unless kept.last.equals?(points.last)
      kept.map { |point| rounded(point) }
    end

    def rounded(point)
      [ point.x.round(COORD_PRECISION), point.y.round(COORD_PRECISION) ]
    end

    # simplestyle-spec — a Static Images API já sabe desenhar essas propriedades por cima do
    # mapa. Polígono ganha preenchimento; linha e ponto não têm área, só contorno/marcador.
    def geojson_properties
      case @geometry
      when RGeo::Feature::Polygon
        { stroke: STROKE_COLOR, "stroke-width": 3, fill: FILL_COLOR, "fill-opacity": 0.25 }
      when RGeo::Feature::LineString, RGeo::Feature::MultiLineString
        { stroke: STROKE_COLOR, "stroke-width": 4 }
      else
        { "marker-color": STROKE_COLOR, "marker-size": "small" }
      end
    end
end
