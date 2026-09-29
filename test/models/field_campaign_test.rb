require "test_helper"

class FieldCampaignTest < ActiveSupport::TestCase
  setup do
    @pricing = project_pricings(:priced_pricing)
    @campaign = field_campaigns(:campo_servico)
  end

  # Jornada de 8h; deslocamento de até meia hora por trecho não conta (decisão do consultor, 2026-09-29).
  test "effective_days grows with the daily commute to the lodging" do
    @campaign.days = 5
    {
      0.25 => 5,  # 15 min por trecho: dentro da tolerância
      0.5 => 5,   # exatamente na tolerância
      1 => 7,     # 2h/dia → 6h úteis → 5 × 8 ÷ 6 = 6,67 → 7
      2 => 10,    # 4h/dia → 4h úteis → 10
      3 => 20     # 6h/dia → 2h úteis → 20
    }.each do |hours, expected|
      @campaign.commute_hours = hours
      assert_equal expected, @campaign.effective_days, "#{hours}h por trecho"
    end
  end

  test "commute_warning? above 2h per leg" do
    @campaign.commute_hours = 2
    assert_not @campaign.commute_warning?
    @campaign.commute_hours = 2.1
    assert @campaign.commute_warning?
  end

  test "commute enters the fuel and stretches vehicle, meals and lodging" do
    @pricing.assign_attributes(distance_km: 100, daily_km: 100, rental_per_day: 150, fuel_price_per_liter: 8,
      vehicle_consumption_km_per_liter: 8, meal_per_person_per_day: 80, lodging_per_person_per_night: 200)
    @campaign.assign_attributes(days: 2, travel_days: 0, commute_km: 120, commute_hours: 2)

    breakdown = @campaign.breakdown(@pricing)

    # 2 dias → 4 dias (4h úteis); km = 2 × 100 + (100 + 2 × 120) × 4 = 1.560
    assert_equal 4, @campaign.effective_days
    assert_equal 1 * 4 * 150, breakdown[:vehicle]
    assert_equal 1560 / 8.0 * 8, breakdown[:fuel]
    assert_equal 1 * 4 * 80, breakdown[:meals]
    assert_equal 1 * 3 * 200, breakdown[:lodging]
  end

  test "lodging rate follows the chosen mode" do
    @pricing.lodging_per_person_per_night = 220
    assert_equal 220, @campaign.lodging_rate(@pricing)

    @campaign.assign_attributes(lodging_mode: "hotel", lodging_price_per_night: 180)
    assert_equal 180, @campaign.lodging_rate(@pricing)

    @campaign.assign_attributes(lodging_mode: "alojamento", lodging_name: "Casa na vila", lodging_price_per_night: 90)
    assert_equal 90, @campaign.lodging_rate(@pricing)

    @campaign.lodging_mode = "cliente"
    assert_equal 0, @campaign.lodging_rate(@pricing)
  end

  test "lodging_pending? only when there is an overnight stay and nothing was chosen" do
    @campaign.assign_attributes(days: 1, travel_days: 0)
    assert_not @campaign.lodging_pending? # bate-volta, sem pernoite
    @campaign.travel_days = 2
    assert @campaign.lodging_pending?
    @campaign.lodging_mode = "cliente"
    assert_not @campaign.lodging_pending?
  end

  test "alojamento needs a description and a price" do
    @campaign.lodging_mode = "alojamento"
    assert_not @campaign.valid?
    assert @campaign.errors[:lodging_name].any?
    assert @campaign.errors[:lodging_price_per_night].any?
  end

  test "unknown municipality is a validation error, not a silent fallback" do
    @campaign.municipality_query = "Cidade Que Não Existe/BA"
    assert_not @campaign.valid?
    assert_match(/não encontrado/, @campaign.errors.full_messages.to_sentence)
  end

  test "changing the campaign municipality recomputes its route and drops the previous hotel search" do
    remanso = create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    @campaign.update!(lodging_mode: "hotel", lodging_name: "Hotel X", lodging_price_per_night: 150, commute_km: 30,
      commute_hours: 0.5, lodging_options: [ { "id" => "1" } ])

    without_mapbox_directions { @campaign.update!(municipality_query: "remanso / ba") }

    assert_equal remanso, @campaign.ibge_municipality
    assert @campaign.distance_km.positive?
    assert_equal 2, @campaign.travel_days # Remanso fica a bem mais de 3h da sede
    assert_nil @campaign.lodging_mode
    assert_empty @campaign.lodging_options
    assert_equal 0, @campaign.commute_km
  end

  test "choose_lodging! takes the option and computes the route to the area" do
    create_municipality(name: "Remanso", uf: "BA", lon: -42.2, lat: -9.7)
    without_mapbox_directions { @campaign.update!(municipality_query: "Remanso/BA") }
    @campaign.update!(lodging_options: [
      { "id" => "abc", "name" => "Pousada Rio", "city" => "Pilão Arcado", "price_per_night" => 140.0,
        "url" => "https://example.com/p", "lat" => -9.1, "lng" => -42.1 },
      { "id" => "same", "name" => "Pousada Centro", "city" => "Remanso", "price_per_night" => 120.0,
        "url" => "https://example.com/s", "lat" => -9.62, "lng" => -42.08 }
    ])

    without_mapbox_directions { assert @campaign.choose_lodging!("abc", @pricing) }

    @campaign.reload
    assert_equal "hotel", @campaign.lodging_mode
    assert_equal 140, @campaign.lodging_price_per_night
    assert @campaign.commute_km.positive?
    assert @campaign.commute_hours.positive?
    assert_not @campaign.choose_lodging!("nao-existe", @pricing)

    # Sem KMZ, a "área" é o centroide do município — hotel na própria cidade fica sem deslocamento
    # (achado ao vivo: pousada no centro de Remanso dava 1h12 até o centroide).
    without_mapbox_directions { @campaign.choose_lodging!("same", @pricing) }
    assert_equal [ 0, 0 ], [ @campaign.reload.commute_km, @campaign.commute_hours ]
  end
end
