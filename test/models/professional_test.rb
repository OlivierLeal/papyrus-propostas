require "test_helper"

class ProfessionalTest < ActiveSupport::TestCase
  test "valid with required fields" do
    professional = Professional.new(name: "Fulano", role: "Engenheiro", rate_man_hour: 100, rate_daily: 150)
    assert professional.valid?
  end

  test "requires name, role, rate_man_hour and rate_daily" do
    professional = Professional.new
    assert_not professional.valid?
    assert_includes professional.errors[:name], "não pode ficar em branco"
    assert_includes professional.errors[:role], "não pode ficar em branco"
    assert_includes professional.errors[:rate_man_hour], "não pode ficar em branco"
    assert_includes professional.errors[:rate_daily], "não pode ficar em branco"
  end

  test "rejects negative rates" do
    professional = Professional.new(name: "Fulano", role: "Engenheiro", rate_man_hour: -1, rate_daily: -1)
    assert_not professional.valid?
  end

  test "accepts zero rates" do
    professional = Professional.new(name: "Fulano", role: "Engenheiro", rate_man_hour: 0, rate_daily: 0)
    assert professional.valid?
  end

  test "active scope only returns active professionals" do
    assert_includes Professional.active, professionals(:coordenador)
    assert_not_includes Professional.active, professionals(:inativo)
  end

  test "always_included scope only returns professionals flagged as always included" do
    assert_includes Professional.always_included, professionals(:diretora)
    assert_not_includes Professional.always_included, professionals(:coordenador)
  end

  test "cannot be destroyed while referenced by proposal_professionals" do
    professional = professionals(:coordenador)
    assert_no_difference "Professional.count" do
      professional.destroy
    end
    assert_includes professional.errors[:base], "Não é possível excluir o registro pois existem proposal professionals dependentes"
  end

  # Relato do consultor (2026-09): preencher o valor da hora-homem em Configurações depois de a
  # proposta existir não chegava na Tela de Precificação — o subtotal gravado ficava o antigo.
  test "alterar o valor da hora-homem recalcula as propostas não aprovadas em que o profissional está" do
    pricing = project_pricings(:priced_pricing)
    line = proposal_professionals(:coordenacao_line) # 40 HH, 0 diárias, BDI 1,20 × impostos 1,25

    professionals(:coordenador).update!(rate_man_hour: 300)

    assert_equal 18_000, line.reload.subtotal # 40 × 300 × 1,5
    assert_equal pricing.proposal_professionals.sum(:subtotal) + pricing.logistics_total + pricing.external_costs_total,
      pricing.reload.total_value
  end

  test "alterar o valor da diária também recalcula" do
    professionals(:biologa).update!(rate_daily: 300)

    assert_equal 29_700, proposal_professionals(:fauna_flora_line).reload.subtotal # (30 × 180 + 48 × 300) × 1,5
  end

  test "não mexe no preço de proposta aprovada" do
    proposals(:priced_proposal).update!(status: "approved")

    professionals(:coordenador).update!(rate_man_hour: 300)

    assert_equal 15_000, proposal_professionals(:coordenacao_line).reload.subtotal
  end

  test "alterar outro campo não dispara recálculo" do
    proposal_professionals(:coordenacao_line).update_columns(subtotal: 1)

    professionals(:coordenador).update!(registration: "CREA 1")

    assert_equal 1, proposal_professionals(:coordenacao_line).reload.subtotal
  end
end
