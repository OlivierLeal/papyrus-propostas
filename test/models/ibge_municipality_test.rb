require "test_helper"

class IbgeMunicipalityTest < ActiveSupport::TestCase
  FACTORY = RGeo::Geographic.spherical_factory(srid: 4326)

  test "requires code_ibge, name and uf" do
    municipio = IbgeMunicipality.new(geom: square(0, 0, 1))
    assert_not municipio.valid?
    assert_includes municipio.errors.attribute_names, :code_ibge
    assert_includes municipio.errors.attribute_names, :name
    assert_includes municipio.errors.attribute_names, :uf
  end

  test "code_ibge is unique" do
    create_municipio(code_ibge: "2800100", name: "Amparo do São Francisco", square_at: [ -37.0, -10.0 ])
    dup = IbgeMunicipality.new(code_ibge: "2800100", name: "Outro", uf: "SE", geom: square(0, 0, 1))
    assert_not dup.valid?
    assert_includes dup.errors.attribute_names, :code_ibge
  end

  test ".intersecting finds municipalities whose polygon contains the given point, via ST_Intersects" do
    dentro = create_municipio(code_ibge: "2800308", name: "Aracaju", square_at: [ -37.1, -11.0 ])
    fora = create_municipio(code_ibge: "3550308", name: "São Paulo", square_at: [ -46.6, -23.5 ])

    ponto = "SRID=4326;POINT(-37.07 -10.97)" # dentro do quadrado de Aracaju definido acima

    found = IbgeMunicipality.intersecting(ponto)

    assert_includes found, dentro
    assert_not_includes found, fora
  end

  private
    def square(lon0, lat0, size)
      ring = [
        [ lon0, lat0 ], [ lon0 + size, lat0 ], [ lon0 + size, lat0 + size ], [ lon0, lat0 + size ], [ lon0, lat0 ]
      ].map { |lon, lat| FACTORY.point(lon, lat) }
      FACTORY.multi_polygon([ FACTORY.polygon(FACTORY.linear_ring(ring)) ])
    end

    def create_municipio(code_ibge:, name:, square_at:)
      lon0, lat0 = square_at
      IbgeMunicipality.create!(code_ibge: code_ibge, name: name, uf: "SE", geom: square(lon0, lat0, 1))
    end
end
