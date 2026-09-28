require "test_helper"

class ProjectPricingTest < ActiveSupport::TestCase
  test "professionals_total sums the subtotal of every line" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 15000.0 + 28260.0, pricing.professionals_total
  end

  # A fixture tem 1 campo com custo direto de R$ 1.100 (ver field_campaigns.yml) — × BDI 1,20 ×
  # impostos 1,25 = R$ 1.650 (2026-09-28: a logística passou a levar o multiplicador, como na
  # planilha da Papyrus).
  test "logistics_total is the field campaigns of every item, with BDI × taxes" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 1650.0, pricing.logistics_total
  end

  # Conferido linha a linha contra a planilha real 26098_Newave Energia_BESS_Rev00.xlsx
  # (Lauro de Freitas → Ourolândia, 405 km; BDI 1,3 × impostos 1,25; 4x4 R$ 750/dia).
  test "field campaign cost matches the Papyrus spreadsheet (Físico and Socioeconômico blocks)" do
    pricing = project_pricings(:priced_pricing)
    pricing.assign_attributes(distance_km: 405, daily_km: 100, bdi: 1.3, tax_multiplier: 1.25, rental_4x4_per_day: 750,
      fuel_price_per_liter: 8, vehicle_consumption_km_per_liter: 8, meal_per_person_per_day: 100,
      lodging_per_person_per_night: 220, toll_price: 30, wash_price: 80, uber_price: 70)

    fisico = FieldCampaign.new(description: "Físico – 01 geólogo", people: 1, days: 1, travel_days: 2, vehicles: 1,
      vehicle_type: "4x4", tolls: 2, washes: 1, uber_trips: 2)
    with_multiplier = fisico.breakdown(pricing).transform_values { |value| (value * pricing.multiplier).round(2) }
    assert_equal 3656.25, with_multiplier[:vehicle]   # Transporte 3 × 1 × 750
    assert_equal 1478.75, with_multiplier[:fuel]      # Gasolina 113,75 L × 8
    assert_equal 487.5, with_multiplier[:meals]       # Alimentação 3 × 100
    assert_equal 715.0, with_multiplier[:lodging]     # Hospedagem 2 × 220
    assert_equal 97.5 + 130 + 227.5, with_multiplier[:extras] # pedágio + lavagem + Uber

    socio = FieldCampaign.new(description: "Sócio", people: 2, days: 2, travel_days: 2, vehicles: 1, vehicle_type: "4x4")
    socio_breakdown = socio.breakdown(pricing).transform_values { |value| (value * pricing.multiplier).round(2) }
    assert_equal [ 4875.0, 1641.25, 1300.0, 2145.0 ], socio_breakdown.values_at(:vehicle, :fuel, :meals, :lodging)
  end

  test "an item sums its team, campaigns and closed costs; the total adds the external costs" do
    pricing = project_pricings(:priced_pricing)
    item = pricing_items(:servico_item)
    item.update!(costs: [ { "description" => "ART", "quantity" => 2, "unit_value" => 300 } ])
    pricing.update!(external_costs: [ { "description" => "Taxa", "value" => 100 } ])
    pricing.recalculate!

    assert_equal 900.0, item.reload.costs_total # 600 × 1,5
    assert_equal 43260 + 1650 + 900, item.total
    assert_equal 43260 + 1650 + 900 + 100, pricing.reload.total_value
  end

  test "price_rows: one line per item plus the external costs, summing to the total" do
    pricing = project_pricings(:priced_pricing)
    campo = pricing.pricing_items.create!(name: "Campanhas de campo", position: 1)
    proposal_professionals(:fauna_flora_line).update!(pricing_item: campo)
    pricing.update!(external_costs: [ { "description" => "ART", "value" => 99.99 } ])
    pricing.recalculate!

    rows = pricing.reload.price_rows
    assert_equal [ "Execução do serviço", "Campanhas de campo", ProjectPricing::EXTERNAL_COSTS_LABEL ], rows.map(&:first)
    assert_equal [ 15000 + 1650, 28260 ], rows.first(2).map(&:last)
    assert_equal pricing.total_value, rows.sum(&:last)
  end

  test "enterprise_totals: own items plus the common ones split equally or proportionally" do
    pricing = project_pricings(:priced_pricing)
    irece = pricing.pricing_enterprises.create!(name: "Irecê")
    brumado = pricing.pricing_enterprises.create!(name: "Brumado", position: 1)
    common = pricing_items(:servico_item) # 15.000 (coordenação) + 1.650 (campo) = 16.650
    own_irece = pricing.pricing_items.create!(name: "EMI Irecê", pricing_enterprise: irece, position: 1)
    proposal_professionals(:fauna_flora_line).update!(pricing_item: own_irece) # 28.260
    pricing.recalculate!

    assert_equal [ [ "Irecê", 28260 + 8325 ], [ "Brumado", 8325 ] ], pricing.reload.enterprise_totals

    pricing.update!(common_split: "proportional")
    assert_equal [ [ "Irecê", 28260 + 16650 ], [ "Brumado", 0 ] ], pricing.enterprise_totals
    assert_equal pricing.total_value, pricing.enterprise_totals.sum(&:last)
    assert common.persisted?
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

  test "suggest_logistics! fills distance/travel_hours from the resolved destination" do
    pricing = project_pricings(:priced_pricing)
    destination = KmzGeometryExtractor::FACTORY.point(-39.5, -14.0)
    fake_result = Logistics::MapboxDirections::Result.new(distance_km: 300.0, duration_hours: 5.0)
    fake_directions = fake_mapbox_directions(fake_result)

    stub_class_method(Logistics::DestinationResolver, :call, ->(_proposal) { destination }) do
      stub_class_method(Logistics::MapboxDirections, :new, ->(*) { fake_directions }) { pricing.suggest_logistics! }
    end

    assert_equal 300.0, pricing.reload.distance_km
    assert_equal 5.0, pricing.travel_hours
    assert_equal 2, pricing.default_travel_days # viagem de 5h: campo novo já vem com ida e volta
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
    pricing.proposal_professionals.find_by(deliverable_name: "Coordenação geral").update!(man_hours: 10, field_days: 0)

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
  test "payment_schedule_amounts: a última parcela absorve o arredondamento e a soma bate com o total" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(payment_schedule: [ { "label" => "A", "percentage" => 33.33 }, { "label" => "B", "percentage" => 33.33 }, { "label" => "C", "percentage" => 33.34 } ])
    pricing.update_columns(total_value: 1000.01)

    amounts = pricing.payment_schedule_amounts.map { |item| item["amount"] }

    assert_equal 1000.01.to_d, amounts.sum.to_d.round(2)
  end

  test "payment_schedule_items= substitui as parcelas, descarta linha sem marco e aceita vírgula" do
    pricing = project_pricings(:priced_pricing)

    pricing.payment_schedule_items = {
      "0" => { "label" => "Assinatura", "percentage" => "40", "date" => "2026-10-01" },
      "1" => { "label" => "", "percentage" => "10", "date" => "" },
      "2" => { "label" => "Relatório", "percentage" => "37,5", "date" => "" },
      "3" => { "label" => "Final", "percentage" => "22.5", "date" => "" }
    }

    assert pricing.save
    assert_equal [ { "label" => "Assinatura", "percentage" => 40, "date" => "2026-10-01" },
                   { "label" => "Relatório", "percentage" => 37.5 },
                   { "label" => "Final", "percentage" => 22.5 } ], pricing.reload.payment_schedule
  end

  test "não salva desembolso que não soma 100%" do
    pricing = project_pricings(:priced_pricing)
    pricing.payment_schedule_items = [ { "label" => "Assinatura", "percentage" => "50" } ]

    assert_not pricing.save
    assert_match "100%", pricing.errors[:payment_schedule].first
  end

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
