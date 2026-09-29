require "test_helper"

# Hospedagem longe da área alonga os campos do item; as diárias da equipe do item crescem junto
# (decisão do consultor, 2026-09-29).
class ProposalProfessionalCommuteTest < ActiveSupport::TestCase
  test "field professionals of the item get extra daily rates in the same proportion as the campaigns" do
    pricing = project_pricings(:priced_pricing)
    field_campaigns(:campo_servico).update!(commute_km: 80, commute_hours: 2) # 2 dias → 4 dias

    pricing.recalculate!

    biologa = proposal_professionals(:fauna_flora_line).reload
    coordenacao = proposal_professionals(:coordenacao_line).reload
    assert_equal 48, biologa.commute_extra_days       # 48 diárias × (4 ÷ 2 − 1)
    assert_equal 0, coordenacao.commute_extra_days    # não vai a campo
    # subtotal original (28.260) + 48 diárias × R$ 280 × 1,20 × 1,25
    assert_equal 28260.0 + 48 * 280 * 1.5, biologa.subtotal.to_f
    assert_equal 15000.0, coordenacao.subtotal.to_f
  end

  test "extra daily rates round up to half a day" do
    line = proposal_professionals(:fauna_flora_line)
    line.field_days = 3
    assert_equal 1.5, line.commute_extra_days(1.4) # 3 × 0,4 = 1,2 → 1,5
    assert_equal 0, line.commute_extra_days(1)
  end
end
