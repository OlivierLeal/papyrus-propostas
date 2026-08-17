require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "strips name" do
    user = User.new(name: "  Fulano  ")
    assert_equal("Fulano", user.name)
  end

  test "requires name" do
    user = User.new(email_address: "novo@example.com", password: "segredo123", password_confirmation: "segredo123")
    assert_not user.valid?
    assert_includes user.errors[:name], "não pode ficar em branco"
  end

  test "requires unique email_address" do
    user = User.new(name: "Fulano", email_address: users(:one).email_address, password: "segredo123", password_confirmation: "segredo123")
    assert_not user.valid?
    assert_includes user.errors[:email_address], "já está em uso"
  end

  test "authenticates with correct password" do
    user = users(:one)
    assert user.authenticate("password")
  end

  test "does not authenticate with wrong password" do
    user = users(:one)
    assert_not user.authenticate("senha-errada")
  end

  test "generates a password reset token that resolves back to the user" do
    user = users(:one)
    token = user.generate_token_for(:password_reset)

    assert_equal user, User.find_by_token_for(:password_reset, token)
  end

  test "password reset token is invalidated after the password changes" do
    user = users(:one)
    token = user.generate_token_for(:password_reset)

    user.update!(password: "novaSenha123", password_confirmation: "novaSenha123")

    assert_nil User.find_by_token_for(:password_reset, token)
  end

  test "updating without password keeps the current password" do
    user = users(:one)
    original_digest = user.password_digest

    user.update!(name: "Nome Atualizado", password: "", password_confirmation: "")

    assert_equal original_digest, user.reload.password_digest
    assert_equal "Nome Atualizado", user.name
  end
end
