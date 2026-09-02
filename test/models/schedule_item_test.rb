require "test_helper"

class ScheduleItemTest < ActiveSupport::TestCase
  setup { @pricing = project_pricings(:priced_pricing) }

  test "válido com os campos obrigatórios" do
    item = build_item

    assert item.valid?
  end

  test "recusa schedule_type fora do menu" do
    item = build_item(schedule_type: "outro")

    assert_not item.valid?
    assert_includes item.errors[:schedule_type], "não está incluído na lista"
  end

  test "exige phase_name e activity_name" do
    item = build_item(phase_name: "", activity_name: "")

    assert_not item.valid?
    assert_includes item.errors[:phase_name], "não pode ficar em branco"
    assert_includes item.errors[:activity_name], "não pode ficar em branco"
  end

  test "start_period tem que ser 1 ou mais" do
    item = build_item(start_period: 0)

    assert_not item.valid?
    assert_includes item.errors[:start_period], "deve ser maior ou igual a 1"
  end

  test "duration_periods tem que ser 1 ou mais" do
    item = build_item(duration_periods: 0)

    assert_not item.valid?
    assert_includes item.errors[:duration_periods], "deve ser maior ou igual a 1"
  end

  test "for_type filtra por tipo e ordena por position" do
    servico_2 = @pricing.schedule_items.create!(build_attrs(schedule_type: "servico", position: 2))
    servico_1 = @pricing.schedule_items.create!(build_attrs(schedule_type: "servico", position: 1))
    @pricing.schedule_items.create!(build_attrs(schedule_type: "implantacao", position: 0))

    assert_equal [ servico_1, servico_2 ], @pricing.schedule_items.for_type("servico").to_a
  end

  test "é destruído junto com o project_pricing" do
    item = @pricing.schedule_items.create!(build_attrs)

    assert_difference "ScheduleItem.count", -1 do
      @pricing.destroy
    end
    assert_not ScheduleItem.exists?(item.id)
  end

  private
    def build_attrs(**overrides)
      { schedule_type: "servico", phase_name: "Mobilização", activity_name: "Assinatura do Contrato",
        start_period: 1, duration_periods: 2, position: 0 }.merge(overrides)
    end

    def build_item(**overrides)
      @pricing.schedule_items.build(build_attrs(**overrides))
    end
end
