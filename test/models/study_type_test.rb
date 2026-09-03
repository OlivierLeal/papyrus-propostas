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

  test "match_ai_value matches the exact code the prompt asked for" do
    assert_equal study_types(:eia_rima), StudyType.match_ai_value("eia_rima")
  end

  test "match_ai_value tolerates the AI answering with the name instead of the code" do
    # A IA recebe o menu de códigos mas às vezes devolve o rótulo ("EIA-RIMA", "EIA/RIMA").
    # Isso é ruído de formato, não falta de cadastro — o sistema resolve sozinho.
    assert_equal study_types(:eia_rima), StudyType.match_ai_value("EIA-RIMA")
    assert_equal study_types(:eia_rima), StudyType.match_ai_value("EIA / RIMA")
  end

  test "match_ai_value returns nil for a code that simply isn't registered" do
    # "eai" (Estudo Ambiental Intermediário) foi o caso real da conversa 31, em produção.
    assert_nil StudyType.match_ai_value("eai")
    assert_nil StudyType.match_ai_value("")
  end

  test "has many study_templates" do
    assert_includes study_types(:eia_rima).study_templates, study_templates(:coordenacao_eia_rima)
  end
end
