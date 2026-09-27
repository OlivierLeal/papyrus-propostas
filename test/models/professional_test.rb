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
end
