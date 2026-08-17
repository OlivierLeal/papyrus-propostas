require "test_helper"

class ProposalProfessionalTest < ActiveSupport::TestCase
  test "recalculate_subtotal applies BDI and taxes over office and field hours" do
    line = proposal_professionals(:coordenacao_line)
    line.hours_office = 40
    line.hours_field = 0

    line.recalculate_subtotal(bdi: 1.20, tax_multiplier: 1.25)

    # C1 = 40h * 250 = 10000; C2 = 0; C3 = 10000 * 1.20 * 1.25 = 15000
    assert_equal 15000.0, line.subtotal
  end

  test "recalculate_subtotal includes field hours at the field rate" do
    line = proposal_professionals(:fauna_flora_line)
    line.hours_office = 30
    line.hours_field = 48

    line.recalculate_subtotal(bdi: 1.20, tax_multiplier: 1.25)

    # C1 = 30h * 180 = 5400; C2 = 48h * 280 = 13440; C3 = 18840 * 1.20 * 1.25 = 28260
    assert_equal 28260.0, line.subtotal
  end

  test "requires deliverable_name" do
    line = ProposalProfessional.new(project_pricing: project_pricings(:priced_pricing), professional: professionals(:coordenador), hours_office: 1, hours_field: 1)
    assert_not line.valid?
    assert_includes line.errors[:deliverable_name], "não pode ficar em branco"
  end

  test "rejects negative hours" do
    line = ProposalProfessional.new(
      project_pricing: project_pricings(:priced_pricing),
      professional: professionals(:coordenador),
      deliverable_name: "Teste",
      hours_office: -1,
      hours_field: -1
    )
    assert_not line.valid?
  end
end
