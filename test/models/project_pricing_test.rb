require "test_helper"

class ProjectPricingTest < ActiveSupport::TestCase
  test "professionals_total sums the subtotal of every line" do
    pricing = project_pricings(:priced_pricing)
    assert_equal 15000.0 + 28260.0, pricing.professionals_total
  end

  test "logistics_total combines daily rates over the days plus fuel" do
    pricing = project_pricings(:priced_pricing)
    # (150 + 80) * 5 dias + 500 combustível = 1650
    assert_equal 1650.0, pricing.logistics_total
  end

  test "external_costs_total sums the jsonb list" do
    pricing = project_pricings(:priced_pricing)
    pricing.external_costs = [ { "description" => "ART", "value" => 350 }, { "description" => "Laudo fauna", "value" => 1200.50 } ]

    assert_equal 1550.50, pricing.external_costs_total
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
end
