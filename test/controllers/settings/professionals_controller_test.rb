require "test_helper"

class Settings::ProfessionalsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index lists professionals" do
    get settings_professionals_path
    assert_response :success
  end

  test "new renders the creation form" do
    get new_settings_professional_path
    assert_response :success
  end

  test "create persists a valid professional" do
    assert_difference "Professional.count", 1 do
      post settings_professionals_path, params: {
        professional: { name: "Ana Souza", role: "Engenheira Florestal", rate_office: "220.00", rate_field: "320.00", active: "1" }
      }
    end

    assert_redirected_to settings_professionals_path
  end

  test "create re-renders the form when a required field is missing" do
    assert_no_difference "Professional.count" do
      post settings_professionals_path, params: { professional: { name: "", role: "Engenheira", rate_office: "220.00", rate_field: "320.00" } }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the edit form" do
    get edit_settings_professional_path(professionals(:coordenador))
    assert_response :success
  end

  test "update changes rates" do
    professional = professionals(:coordenador)

    patch settings_professional_path(professional), params: {
      professional: { name: professional.name, role: professional.role, rate_office: "300.00", rate_field: "400.00" }
    }

    assert_redirected_to settings_professionals_path
    professional.reload
    assert_equal 300.00, professional.rate_office
  end

  test "update re-renders the edit form when a required field is invalid" do
    professional = professionals(:coordenador)

    patch settings_professional_path(professional), params: {
      professional: { name: "", role: professional.role, rate_office: "300.00", rate_field: "400.00" }
    }

    assert_response :unprocessable_entity
    assert_equal "Pedro Almeida", professional.reload.name
  end

  test "destroy removes a professional with no dependent proposal_professionals" do
    disposable = Professional.create!(name: "Descartável", role: "Estagiário", rate_office: 50, rate_field: 80, active: true)

    assert_difference "Professional.count", -1 do
      delete settings_professional_path(disposable)
    end

    assert_redirected_to settings_professionals_path
  end

  test "destroy fails gracefully when the professional is referenced by a proposal" do
    referenced = professionals(:coordenador)

    assert_no_difference "Professional.count" do
      delete settings_professional_path(referenced)
    end
  end
end
