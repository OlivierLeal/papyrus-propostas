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

  # Sem KMZ (2026-09-29): o local vem do ET/TR/chat, via achados "municipios".
  test "without KMZ, uses an unambiguous municipality from the findings" do
    create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    conversation = conversations(:reviewing_conversation)
    conversation.project_findings.create!(field: "municipios", value: "Remanso/BA", nature: "fato", source_kind: "et")

    destination = Logistics::DestinationResolver.resolve(Proposal.new(conversation: conversation))

    assert_equal "Remanso/BA", destination.label
    assert_equal "Pedido Técnico do Estudo (ET)", destination.source
  end

  test "ignores an ambiguous municipality name without UF" do
    create_municipality(name: "Bom Jesus", uf: "PI", lon: -44.4, lat: -9.1)
    create_municipality(name: "Bom Jesus", uf: "RS", lon: -50.4, lat: -28.7)
    conversation = conversations(:reviewing_conversation)
    conversation.project_findings.create!(field: "municipios", value: "Bom Jesus", nature: "fato", source_kind: "et")

    assert_nil Logistics::DestinationResolver.call(Proposal.new(conversation: conversation))
  end

  test "the consultant's finding wins over the ET's" do
    create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    create_municipality(name: "Irecê", uf: "BA", lon: -41.9, lat: -11.3)
    conversation = conversations(:reviewing_conversation)
    conversation.project_findings.create!(field: "municipios", value: "Remanso/BA", nature: "fato", source_kind: "et")
    conversation.project_findings.create!(field: "municipios", value: "Irecê/BA", nature: "fato", source_kind: "consultor")

    assert_equal "Irecê/BA", Logistics::DestinationResolver.resolve(Proposal.new(conversation: conversation)).label
  end

  test "the project location typed by the consultant wins over the KMZ" do
    irece = create_municipality(name: "Irecê", uf: "BA", lon: -41.9, lat: -11.3)
    proposal = proposals(:priced_proposal)
    proposal.conversation.create_geospatial_result!(geometry_type: "polygon", centroid: FACTORY.point(-39.5, -14.0))
    proposal.project_pricing.update!(ibge_municipality: irece)

    destination = Logistics::DestinationResolver.resolve(proposal)

    assert_equal "Irecê/BA", destination.label
    assert_equal "informado pelo consultor", destination.source
  end

  private
    def square(lon0, lat0, size)
      ring = [
        [ lon0, lat0 ], [ lon0 + size, lat0 ], [ lon0 + size, lat0 + size ], [ lon0, lat0 + size ], [ lon0, lat0 ]
      ].map { |lon, lat| FACTORY.point(lon, lat) }
      FACTORY.multi_polygon([ FACTORY.polygon(FACTORY.linear_ring(ring)) ])
    end
end
