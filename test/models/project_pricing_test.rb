require "test_helper"

class ProjectPricingTest < ActiveSupport::TestCase
  test "professionals_total sums the subtotal of every line" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 15000.0 + 28260.0, pricing.professionals_total
  end

  # priced_pricing tem 1 profissional em campo (biologa, hours_field > 0) e vehicles_count
  # default (1) — por isso o total bate igual ao formato antigo (150+80)*5+500, mesmo a fórmula
  # agora multiplicando por pessoas/veículos (ver os testes específicos abaixo pra >1 de cada).
  test "logistics_total combines per-person lodging/meals, per-vehicle rental over the days, plus fuel" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 1650.0, pricing.logistics_total
  end

  test "field_professionals_count counts only lines with hours_field > 0, minimum 1" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 1, pricing.field_professionals_count # só a bióloga (hours_field: 48)

    pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral").update!(hours_field: 10)
    assert_equal 2, pricing.field_professionals_count

    pricing.proposal_professionals.update_all(hours_field: 0)
    assert_equal 1, pricing.field_professionals_count # nunca zero
  end

  test "logistics_total multiplies meals/lodging by the number of field professionals" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(lodging_per_person_per_night: 100, meal_per_person_per_day: 50, rental_per_day: 0, fuel_total: 0)
    pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral").update!(hours_field: 10)
    # 2 pessoas em campo agora (coordenação + bióloga)

    assert_equal (100 + 50) * 2 * 5, pricing.logistics_total
  end

  test "logistics_total multiplies vehicle rental by vehicles_count, not by people" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(rental_per_day: 200, vehicles_count: 3, lodging_per_person_per_night: 0, meal_per_person_per_day: 0, fuel_total: 0)

    assert_equal 200 * 3 * 5, pricing.logistics_total
  end

  test "long_distance? is true above the km or hour threshold" do
    pricing = project_pricings(:priced_pricing)

    pricing.distance_km = ProjectPricing::LONG_DISTANCE_KM_THRESHOLD + 1
    assert pricing.long_distance?

    pricing.distance_km = 10
    pricing.travel_hours = ProjectPricing::LONG_DISTANCE_HOURS_THRESHOLD + 1
    assert pricing.long_distance?

    pricing.travel_hours = 1
    assert_not pricing.long_distance?
  end

  test "suggest_logistics! fills distance/travel_hours/vehicles/fuel from the resolved destination" do
    pricing = project_pricings(:priced_pricing)
    destination = KmzGeometryExtractor::FACTORY.point(-39.5, -14.0)
    fake_result = Logistics::MapboxDirections::Result.new(distance_km: 300.0, duration_hours: 5.0)
    fake_directions = fake_mapbox_directions(fake_result)

    stub_class_method(Logistics::DestinationResolver, :call, ->(_proposal) { destination }) do
      stub_class_method(Logistics::MapboxDirections, :new, ->(*) { fake_directions }) { pricing.suggest_logistics! }
    end

    assert_equal 300.0, pricing.reload.distance_km
    assert_equal 5.0, pricing.travel_hours
    assert_equal 1, pricing.vehicles_count # 1 pessoa em campo, 4 por veículo
    expected_fuel = ((300.0 * 2 * 1) / pricing.vehicle_consumption_km_per_liter) * pricing.fuel_price_per_liter
    assert_equal expected_fuel.round(2), pricing.fuel_total.round(2)
  end

  test "suggest_logistics! does not compute fuel when the distance is long enough to suggest flying" do
    pricing = project_pricings(:priced_pricing)
    destination = KmzGeometryExtractor::FACTORY.point(-39.5, -14.0)
    fake_result = Logistics::MapboxDirections::Result.new(distance_km: 2000.0, duration_hours: 20.0)
    fake_directions = fake_mapbox_directions(fake_result)

    stub_class_method(Logistics::DestinationResolver, :call, ->(_proposal) { destination }) do
      stub_class_method(Logistics::MapboxDirections, :new, ->(*) { fake_directions }) { pricing.suggest_logistics! }
    end

    assert pricing.reload.long_distance?
    assert_equal 0, pricing.fuel_total
  end

  test "suggest_logistics! does nothing when no destination can be resolved" do
    pricing = project_pricings(:priced_pricing)
    original_distance = pricing.distance_km
    stub_class_method(Logistics::DestinationResolver, :call, ->(_proposal) { nil }) { pricing.suggest_logistics! }

    assert_equal original_distance, pricing.reload.distance_km
  end

  test "suggest_logistics! never raises, even if the destination resolver blows up" do
    pricing = project_pricings(:priced_pricing)
    stub_class_method(Logistics::DestinationResolver, :call, ->(_proposal) { raise "boom" }) do
      assert_nothing_raised { pricing.suggest_logistics! }
    end
  end

  test "external_costs_total sums the jsonb list" do
    pricing = project_pricings(:priced_pricing)
    pricing.external_costs = [ { "description" => "ART", "value" => 350 }, { "description" => "Laudo fauna", "value" => 1200.50 } ]

    assert_equal 1550.50, pricing.external_costs_total
  end

  # Serviços Terceirizados (2026-09) — mesma lista de sempre (external_costs), só particionada
  # por `kind` pra exibição separada na Tela de Precificação (preço continua somando os dois).
  test "outsourced_costs and other_external_costs partition the same jsonb list by kind, keeping the original index" do
    pricing = project_pricings(:priced_pricing)
    pricing.external_costs = [
      { "description" => "ART", "value" => 350 },
      { "description" => "Topografia", "value" => 1200, "kind" => "terceirizado" },
      { "description" => "Laudo fauna", "value" => 800 }
    ]

    assert_equal [ [ "Topografia", 1 ] ], pricing.outsourced_costs.map { |cost, index| [ cost["description"], index ] }
    assert_equal [ [ "ART", 0 ], [ "Laudo fauna", 2 ] ], pricing.other_external_costs.map { |cost, index| [ cost["description"], index ] }
  end

  test "external_costs_total sums outsourced and other costs together" do
    pricing = project_pricings(:priced_pricing)
    pricing.external_costs = [
      { "description" => "ART", "value" => 350 },
      { "description" => "Topografia", "value" => 1200, "kind" => "terceirizado" }
    ]

    assert_equal 1550.0, pricing.external_costs_total
  end

  test "recalculate! updates every line subtotal and the total_value" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(bdi: 1.20, tax_multiplier: 1.25)
    pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral").update!(hours_office: 10, hours_field: 0)

    pricing.recalculate!

    line = pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral")
    assert_equal 3750.0, line.reload.subtotal # 10h * 250 * 1.20 * 1.25

    expected_total = (pricing.professionals_total + pricing.logistics_total + pricing.external_costs_total).round(2)
    assert_equal expected_total, pricing.reload.total_value
  end

  test "payment_schedule_amounts computes the percentage of the total for each item" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(total_value: 1000)

    amounts = pricing.payment_schedule_amounts

    assert_equal 4, amounts.size
    assert_equal 300.0, amounts.find { |item| item["label"] == "Assinatura do contrato" }["amount"]
    assert_equal 600.0, amounts.find { |item| item["label"] == "Protocolo no órgão ambiental" }["amount"]
    assert_equal 50.0, amounts.find { |item| item["label"] == "Vistoria" }["amount"]
    assert_equal 50.0, amounts.find { |item| item["label"] == "Emissão da licença" }["amount"]
  end

  test "requires bdi and tax_multiplier greater than 0" do
    pricing = project_pricings(:priced_pricing)
    pricing.bdi = 0

    assert_not pricing.valid?
  end

  test "requires non-negative logistics parameters" do
    pricing = project_pricings(:priced_pricing)
    pricing.distance_km = -1

    assert_not pricing.valid?
  end

  test "requires vehicles_count to be at least 1" do
    pricing = project_pricings(:priced_pricing)
    pricing.vehicles_count = 0

    assert_not pricing.valid?
  end

  test "requires non-negative fuel price, vehicle consumption and lodging rate" do
    pricing = project_pricings(:priced_pricing)

    pricing.fuel_price_per_liter = -1
    assert_not pricing.valid?

    pricing.fuel_price_per_liter = 6.2
    pricing.vehicle_consumption_km_per_liter = -1
    assert_not pricing.valid?

    pricing.vehicle_consumption_km_per_liter = 10
    pricing.lodging_per_person_per_night = -1
    assert_not pricing.valid?
  end

  # A data de cada parcela mora dentro do payment_schedule (jsonb), junto do marco e do
  # percentual — não é coluna nova.
  test "payment_dates= stores one date per instalment, in order, keeping the rest of the schedule" do
    pricing = project_pricings(:priced_pricing)

    pricing.payment_dates = [ "2026-03-25", "", "2026-05-25" ]
    pricing.save!

    schedule = pricing.reload.payment_schedule
    assert_equal "2026-03-25", schedule[0]["date"]
    assert_nil schedule[1]["date"]
    assert_equal "2026-05-25", schedule[2]["date"]
    assert_equal 30, schedule[0]["percentage"]
    assert_equal "Assinatura do contrato", schedule[0]["label"]
  end

  test "payment_schedule_amounts carries the date alongside the computed amount" do
    pricing = project_pricings(:priced_pricing)
    pricing.payment_dates = [ "2026-03-25" ]
    pricing.save!

    first = pricing.payment_schedule_amounts.first
    assert_equal "2026-03-25", first["date"]
    assert first["amount"].positive?
  end

  private
    def fake_mapbox_directions(result)
      Object.new.tap { |fake| fake.define_singleton_method(:fetch) { result } }
    end
end
