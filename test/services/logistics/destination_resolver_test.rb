require "test_helper"

class Logistics::DestinationResolverTest < ActiveSupport::TestCase
  FACTORY = KmzGeometryExtractor::FACTORY

  test "uses the KMZ centroid directly when present" do
    conversation = conversations(:reviewing_conversation)
    conversation.create_geospatial_result!(geometry_type: "polygon", centroid: FACTORY.point(-39.5, -14.0))
    proposal = Proposal.new(conversation: conversation)

    point = Logistics::DestinationResolver.call(proposal)

    assert_in_delta(-39.5, point.x, 0.0001)
    assert_in_delta(-14.0, point.y, 0.0001)
  end

  # Sem centroide direto (raro — geospatial_result existe mas o KMZ era só ponto/linha sem área,
  # ou proposta antiga), cai pro município já cruzado por ProcessKmzJob (sempre com UF).
  test "falls back to the centroid of the first cross-referenced municipality when there is no KMZ centroid" do
    municipio = IbgeMunicipality.create!(code_ibge: "2913606", name: "Itabuna", uf: "BA", geom: square(-39.3, -14.8, 1))
    conversation = conversations(:reviewing_conversation)
    conversation.create_geospatial_result!(
      geometry_type: "point", municipalities: [ { "code_ibge" => municipio.code_ibge, "name" => municipio.name, "uf" => municipio.uf } ]
    )
    proposal = Proposal.new(conversation: conversation)

    point = Logistics::DestinationResolver.call(proposal)

    assert_in_delta(-38.8, point.x, 0.01) # centroide do quadrado -39.3..-38.3, -14.8..-13.8
    assert_in_delta(-14.3, point.y, 0.01)
  end

  test "returns nil when there is no geospatial_result at all" do
    proposal = Proposal.new(conversation: conversations(:reviewing_conversation))

    assert_nil Logistics::DestinationResolver.call(proposal)
  end

  test "returns nil when geospatial_result has neither a centroid nor any municipality" do
    conversation = conversations(:reviewing_conversation)
    conversation.create_geospatial_result!(geometry_type: "point")
    proposal = Proposal.new(conversation: conversation)

    assert_nil Logistics::DestinationResolver.call(proposal)
  end

  test "returns nil when the cross-referenced municipality's code_ibge isn't in ibge_municipalities" do
    conversation = conversations(:reviewing_conversation)
    conversation.create_geospatial_result!(
      geometry_type: "point", municipalities: [ { "code_ibge" => "0000000", "name" => "Fantasma", "uf" => "BA" } ]
    )
    proposal = Proposal.new(conversation: conversation)

    assert_nil Logistics::DestinationResolver.call(proposal)
  end

  private
    def square(lon0, lat0, size)
      ring = [
        [ lon0, lat0 ], [ lon0 + size, lat0 ], [ lon0 + size, lat0 + size ], [ lon0, lat0 + size ], [ lon0, lat0 ]
      ].map { |lon, lat| FACTORY.point(lon, lat) }
      FACTORY.multi_polygon([ FACTORY.polygon(FACTORY.linear_ring(ring)) ])
    end
end
