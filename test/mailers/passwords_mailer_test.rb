require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "reset sends an email to the user with the right subject" do
    user = users(:one)

    mail = PasswordsMailer.reset(user)

    assert_equal "Reset your password", mail.subject
    assert_equal [ user.email_address ], mail.to
  end
end
