# Município de teste com polígono quadrado (lon0..lon0+size, lat0..lat0+size) e trava da Mapbox
# Directions — sem isso, qualquer rota chamaria a API de verdade (MAPBOX_API_KEY vem do .env em
# qualquer ambiente via dotenv-rails). Com a trava, Logistics::Route cai na linha reta.
module GeoTestHelper
  def create_municipality(name:, uf:, lon:, lat:, size: 0.2, code: nil)
    code ||= format("%07d", IbgeMunicipality.count + 9_900_000)
    ring = [ [ lon, lat ], [ lon + size, lat ], [ lon + size, lat + size ], [ lon, lat + size ], [ lon, lat ] ]
      .map { |x, y| KmzGeometryExtractor::FACTORY.point(x, y) }
    geom = KmzGeometryExtractor::FACTORY.multi_polygon([ KmzGeometryExtractor::FACTORY.polygon(KmzGeometryExtractor::FACTORY.linear_ring(ring)) ])
    IbgeMunicipality.create!(code_ibge: code, name: name, uf: uf, geom: geom)
  end

  def without_mapbox_directions(&block)
    offline = Struct.new(:fetch).new(nil)
    stub_class_method(Logistics::MapboxDirections, :new, ->(*) { offline }, &block)
  end
end
