require "test_helper"

class Lodging::SearchTest < ActiveSupport::TestCase
  # Stay22 falsa: devolve opções conforme o raio pedido e registra as chamadas.
  class FakeClient
    attr_reader :calls

    def initialize(by_radius)
      @by_radius = by_radius
      @calls = []
    end

    def search(lat:, lng:, radius_m:, checkin:, checkout:)
      @calls << { lat: lat, lng: lng, radius_m: radius_m, nights: (checkout - checkin).to_i }
      @by_radius.fetch(radius_m, [])
    end
  end

  setup do
    @campaign = field_campaigns(:campo_servico)
    create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    without_mapbox_directions { @campaign.update!(municipality_query: "Remanso/BA") }
  end

  test "searches 30 km first, widens to 100 km, sorts by distance to the area and stores the options" do
    area = @campaign.area_point
    near = option("a", "Pousada Perto", 180, area.y + 0.05, area.x)
    far = option("b", "Hotel Longe", 120, area.y + 0.6, area.x)
    client = FakeClient.new(30_000 => [ near ], 100_000 => [ far, near ])

    with_stay22_key { Lodging::Search.new(@campaign, client: client).call }

    assert_equal [ 30_000, 100_000 ], client.calls.first(2).map { |c| c[:radius_m] }
    assert_equal 3, client.calls.first[:nights]
    options = @campaign.reload.lodging_options
    assert_equal [ "Pousada Perto", "Hotel Longe" ], options.map { |o| o["name"] }
    assert options.first["commute_km"] < options.last["commute_km"]
    assert @campaign.lodging_searched_at
  end

  test "remote area: searches around the nearest towns beyond 100 km" do
    create_municipality(name: "Cidade Grande", uf: "BA", lon: -41.0, lat: -9.7) # ~130 km a leste
    town = option("c", "Hotel da Cidade", 150, -9.6, -40.9)
    client = FakeClient.new(Lodging::Search::CITY_RADIUS_M => [ town ])

    with_stay22_key { Lodging::Search.new(@campaign, client: client).call }

    assert_includes client.calls.map { |c| c[:radius_m] }, Lodging::Search::CITY_RADIUS_M
    assert_equal [ "Hotel da Cidade" ], @campaign.reload.lodging_options.map { |o| o["name"] }
    assert_match(/Vale considerar alojamento/, @campaign.lodging_search_note)
  end

  test "nothing found tells the consultant to use alojamento or client-provided lodging" do
    with_stay22_key { Lodging::Search.new(@campaign, client: FakeClient.new({})).call }

    assert_empty @campaign.reload.lodging_options
    assert_match(/Nenhuma hospedagem encontrada/, @campaign.lodging_search_note)
  end

  test "without any location it does not call Stay22" do
    @campaign.update!(municipality_query: "")
    client = FakeClient.new({})
    stub_class_method(Logistics::DestinationResolver, :call, ->(*) { nil }) do
      with_stay22_key { Lodging::Search.new(@campaign.reload, client: client).call }
    end

    assert_empty client.calls
    assert_match(/Sem localização/, @campaign.lodging_search_note)
  end

  private
    def option(id, name, price, lat, lng)
      Lodging::Stay22Client::Option.new(id: id, name: name, kind: "Hotel", city: "X", price_per_night: price.to_d,
        url: "https://example.com/#{id}", lat: lat, lng: lng)
    end

    def with_stay22_key
      original = ENV["STAY22_API_KEY"]
      ENV["STAY22_API_KEY"] = "test"
      yield
    ensure
      ENV["STAY22_API_KEY"] = original
    end
end
