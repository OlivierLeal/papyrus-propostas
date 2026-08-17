require "test_helper"

class Settings::DashboardControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:one) }

  test "index shows counts for study types, professionals and study templates" do
    get settings_root_path
    assert_response :success
  end

  test "redirects a guest to the login screen" do
    sign_out
    get settings_root_path
    assert_redirected_to new_session_path
  end
end
