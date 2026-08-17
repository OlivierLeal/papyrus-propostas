require "test_helper"

class Settings::StudyTemplatesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists study templates" do
    get settings_study_templates_path
    assert_response :success
  end

  test "new renders the creation form" do
    get new_settings_study_template_path
    assert_response :success
  end

  test "create persists a valid study template" do
    assert_difference "StudyTemplate.count", 1 do
      post settings_study_templates_path, params: {
        study_template: {
          study_type_id: study_types(:rap).id, professional_id: professionals(:biologa).id,
          deliverable_name: "Diagnóstico do meio biótico", hours_office_default: "20", hours_field_default: "16"
        }
      }
    end

    assert_redirected_to settings_study_templates_path
  end

  test "create re-renders the form when deliverable_name is duplicated for the same type and professional" do
    template = study_templates(:coordenacao_eia_rima)

    assert_no_difference "StudyTemplate.count" do
      post settings_study_templates_path, params: {
        study_template: {
          study_type_id: template.study_type_id, professional_id: template.professional_id,
          deliverable_name: template.deliverable_name, hours_office_default: "10", hours_field_default: "0"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the edit form" do
    get edit_settings_study_template_path(study_templates(:coordenacao_eia_rima))
    assert_response :success
  end

  test "update changes default hours" do
    template = study_templates(:coordenacao_eia_rima)

    patch settings_study_template_path(template), params: {
      study_template: {
        study_type_id: template.study_type_id, professional_id: template.professional_id,
        deliverable_name: template.deliverable_name, hours_office_default: "50", hours_field_default: "0"
      }
    }

    assert_redirected_to settings_study_templates_path
    assert_equal 50, template.reload.hours_office_default
  end

  test "update re-renders the edit form when the update collides with another template's menu key" do
    template = study_templates(:coordenacao_eia_rima)
    other = study_templates(:fauna_flora_eia_rima)

    patch settings_study_template_path(template), params: {
      study_template: {
        study_type_id: other.study_type_id, professional_id: other.professional_id,
        deliverable_name: other.deliverable_name, hours_office_default: "10", hours_field_default: "0"
      }
    }

    assert_response :unprocessable_entity
    assert_equal "Coordenação geral", template.reload.deliverable_name
  end

  test "destroy removes a study template" do
    template = study_templates(:coordenacao_eia_rima)

    assert_difference "StudyTemplate.count", -1 do
      delete settings_study_template_path(template)
    end

    assert_redirected_to settings_study_templates_path
  end
end
