require "test_helper"

class Settings::StudyTypesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists study types" do
    get settings_study_types_path
    assert_response :success
  end

  test "new renders the creation form" do
    get new_settings_study_type_path
    assert_response :success
  end

  test "create persists a valid study type" do
    assert_difference "StudyType.count", 1 do
      post settings_study_types_path, params: { study_type: { name: "PEA", code: "pea", description: "Programa de Educação Ambiental" } }
    end

    assert_redirected_to settings_study_types_path
  end

  test "create re-renders the form when the code is not unique" do
    assert_no_difference "StudyType.count" do
      post settings_study_types_path, params: { study_type: { name: "Duplicado", code: study_types(:eia_rima).code } }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the edit form" do
    get edit_settings_study_type_path(study_types(:eia_rima))
    assert_response :success
  end

  test "update changes the study type" do
    study_type = study_types(:eia_rima)

    patch settings_study_type_path(study_type), params: { study_type: { name: "EIA-RIMA Revisado", code: study_type.code } }

    assert_redirected_to settings_study_types_path
    assert_equal "EIA-RIMA Revisado", study_type.reload.name
  end

  test "update re-renders the edit form when the code collides with another study type" do
    study_type = study_types(:eia_rima)

    patch settings_study_type_path(study_type), params: { study_type: { name: study_type.name, code: study_types(:rap).code } }

    assert_response :unprocessable_entity
    assert_equal "eia_rima", study_type.reload.code
  end

  test "destroy removes a study type with no dependent study_templates" do
    study_type = StudyType.create!(name: "Descartável", code: "descartavel")

    assert_difference "StudyType.count", -1 do
      delete settings_study_type_path(study_type)
    end

    assert_redirected_to settings_study_types_path
  end
end
