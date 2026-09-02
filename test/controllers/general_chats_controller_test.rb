require "test_helper"

class GeneralChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
  end

  test "index lists only the current user's general chats" do
    other_user_chat = users(:two).general_chats.create!

    get general_chats_path

    assert_response :success
    assert_match general_chats(:with_messages).display_title, response.body
    assert_no_match general_chat_path(other_user_chat), response.body
  end

  test "index redirects a guest to the login screen" do
    sign_out
    get general_chats_path
    assert_redirected_to new_session_path
  end

  test "create persists a general chat for the current user, applies system instructions and redirects to it" do
    assert_difference "@user.general_chats.count", 1 do
      post general_chats_path
    end

    general_chat = @user.general_chats.order(:created_at).last
    assert_redirected_to general_chat
    assert general_chat.messages.where(role: "system", internal: true).exists?
  end

  test "show renders an existing general chat belonging to the current user" do
    get general_chat_path(general_chats(:with_messages))
    assert_response :success
  end

  test "show 404s for a general chat belonging to another user" do
    other_chat = users(:two).general_chats.create!

    get general_chat_path(other_chat)
    assert_response :not_found
  end
end
