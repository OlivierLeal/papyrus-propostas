require "test_helper"

class SetProjectLocationToolTest < ActiveSupport::TestCase
  setup do
    @remanso = create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
  end

  test "before the proposal exists it records a consultant finding the resolver will use" do
    conversation = conversations(:reviewing_conversation)

    result = JSON.parse(SetProjectLocationTool.new(conversation: conversation).execute(municipio: "Remanso/BA"))

    assert result["success"]
    finding = conversation.project_findings.find_by(field: "municipios", source_kind: "consultor")
    assert_equal "Remanso/BA", finding.value
    assert_equal "Remanso/BA", Logistics::DestinationResolver.resolve(Proposal.new(conversation: conversation)).label
  end

  test "with a proposal it sets the project location and recomputes the logistics" do
    proposal = proposals(:priced_proposal)

    result = without_mapbox_directions do
      JSON.parse(SetProjectLocationTool.new(conversation: proposal.conversation).execute(municipio: "remanso - ba"))
    end

    assert result["success"]
    pricing = proposal.project_pricing.reload
    assert_equal @remanso, pricing.ibge_municipality
    assert pricing.distance_km > 400
  end

  test "a location for one campaign only changes that campaign" do
    proposal = proposals(:priced_proposal)

    result = without_mapbox_directions do
      JSON.parse(SetProjectLocationTool.new(conversation: proposal.conversation).execute(municipio: "Remanso/BA", campo: "campo"))
    end

    assert result["success"]
    assert_equal @remanso, field_campaigns(:campo_servico).reload.ibge_municipality
    assert_nil proposal.project_pricing.reload.ibge_municipality
  end

  test "an ambiguous name asks for the UF" do
    create_municipality(name: "Bom Jesus", uf: "PI", lon: -44.4, lat: -9.1)
    create_municipality(name: "Bom Jesus", uf: "RS", lon: -50.4, lat: -28.7)

    result = JSON.parse(SetProjectLocationTool.new(conversation: conversations(:reviewing_conversation)).execute(municipio: "Bom Jesus"))

    assert_match(/ambíguo.*Bom Jesus\/PI.*Bom Jesus\/RS|ambíguo.*Bom Jesus\/RS.*Bom Jesus\/PI/, result["error"])
  end
end
