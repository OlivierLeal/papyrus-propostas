require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
  end

  test "index lists users" do
    get users_path
    assert_response :success
  end

  test "new renders the creation form" do
    get new_user_path
    assert_response :success
  end

  test "create persists a new user with a password" do
    assert_difference "User.count", 1 do
      post users_path, params: { user: { name: "Novo Consultor", email_address: "novo@example.com", password: "segredo123", password_confirmation: "segredo123" } }
    end

    assert_redirected_to users_path
  end

  test "create re-renders the form on validation errors" do
    assert_no_difference "User.count" do
      post users_path, params: { user: { name: "", email_address: "novo@example.com", password: "segredo123", password_confirmation: "segredo123" } }
    end

    assert_response :unprocessable_entity
  end

  test "edit renders the edit form" do
    get edit_user_path(users(:two))
    assert_response :success
  end

  test "update changes name and email without touching the password" do
    user = users(:two)
    original_digest = user.password_digest

    patch user_path(user), params: { user: { name: "Consultor Renomeado", email_address: user.email_address, password: "", password_confirmation: "" } }

    assert_redirected_to users_path
    user.reload
    assert_equal "Consultor Renomeado", user.name
    assert_equal original_digest, user.password_digest
  end

  test "update changes the password when a new one is supplied" do
    user = users(:two)

    patch user_path(user), params: { user: { name: user.name, email_address: user.email_address, password: "novaSenha123", password_confirmation: "novaSenha123" } }

    user.reload
    assert user.authenticate("novaSenha123")
  end

  test "update re-renders the edit form when the email collides with another user" do
    user = users(:two)

    patch user_path(user), params: { user: { name: user.name, email_address: users(:one).email_address, password: "", password_confirmation: "" } }

    assert_response :unprocessable_entity
    assert_equal "two@example.com", user.reload.email_address
  end

  test "destroy removes another user" do
    other = users(:two)

    assert_difference "User.count", -1 do
      delete user_path(other)
    end

    assert_redirected_to users_path
  end

  test "destroy refuses to remove your own user" do
    assert_no_difference "User.count" do
      delete user_path(users(:one))
    end

    assert_redirected_to users_path
    follow_redirect!
    assert_match "não pode remover seu próprio usuário", response.body
  end
end
