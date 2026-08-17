require "test_helper"

class StudyTemplateTest < ActiveSupport::TestCase
  test "valid with required fields" do
    template = StudyTemplate.new(
      study_type: study_types(:rap),
      professional: professionals(:coordenador),
      deliverable_name: "Novo entregável",
      hours_office_default: 10,
      hours_field_default: 5
    )
    assert template.valid?
  end

  test "requires deliverable_name unique per study_type and professional" do
    existing = study_templates(:coordenacao_eia_rima)
    duplicate = StudyTemplate.new(
      study_type: existing.study_type,
      professional: existing.professional,
      deliverable_name: existing.deliverable_name,
      hours_office_default: 1,
      hours_field_default: 1
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:deliverable_name], "já está em uso"
  end

  test "allows same deliverable_name for a different study_type" do
    existing = study_templates(:coordenacao_eia_rima)
    template = StudyTemplate.new(
      study_type: study_types(:rap),
      professional: existing.professional,
      deliverable_name: existing.deliverable_name,
      hours_office_default: 1,
      hours_field_default: 1
    )
    assert template.valid?
  end

  test "rejects negative default hours" do
    template = StudyTemplate.new(
      study_type: study_types(:rap),
      professional: professionals(:coordenador),
      deliverable_name: "Entregável negativo",
      hours_office_default: -1,
      hours_field_default: -1
    )
    assert_not template.valid?
  end
end
