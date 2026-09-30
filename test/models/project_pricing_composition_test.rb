require "test_helper"

# Composição do preço (2026-09-30): o BDI e os impostos ficavam embutidos em cada subtotal — com
# logística zerada, "Total" = "Equipe" na tela e parecia que o imposto não tinha sido aplicado.
class ProjectPricingCompositionTest < ActiveSupport::TestCase
  test "custo direto + BDI + impostos + externos fecha exatamente com o total" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(bdi: 1.3, tax_multiplier: 1.25, external_costs: [ { "description" => "ART", "value" => 150 } ])
    pricing.recalculate!

    c = pricing.reload.price_composition

    assert_equal pricing.total_value.to_d, c.values_at(:direct, :bdi, :taxes, :external, :outsourced).sum
    assert_equal c[:direct], c[:team] + c[:logistics] + c[:item_costs]
    assert_equal (c[:direct] * 0.3).round(2), c[:bdi]
    assert_in_delta (c[:direct] * 1.3 * 0.25).to_f, c[:taxes].to_f, 0.05
    assert_equal 150, c[:external]
  end

  test "sem margem (BDI e impostos = 1), tudo é custo direto" do
    pricing = project_pricings(:priced_pricing)
    pricing.update!(bdi: 1, tax_multiplier: 1)
    pricing.recalculate!

    c = pricing.reload.price_composition
    assert_equal 0, c[:bdi]
    assert_equal 0, c[:taxes]
  end
end
