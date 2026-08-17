require "test_helper"

class StudyTypeTest < ActiveSupport::TestCase
  test "valid with name and code" do
    study_type = StudyType.new(name: "PEA", code: "pea")
    assert study_type.valid?
  end

  test "requires name" do
    study_type = StudyType.new(code: "sem_nome")
    assert_not study_type.valid?
  end

  test "requires unique code" do
    study_type = StudyType.new(name: "Duplicado", code: study_types(:eia_rima).code)
    assert_not study_type.valid?
    assert_includes study_type.errors[:code], "já está em uso"
  end

  test "has many study_templates" do
    assert_includes study_types(:eia_rima).study_templates, study_templates(:coordenacao_eia_rima)
  end
end
