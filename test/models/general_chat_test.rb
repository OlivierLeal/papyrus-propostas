require "test_helper"

class GeneralChatTest < ActiveSupport::TestCase
  test "display_title uses the title when present" do
    assert_equal "Qual norma regula supressão de vegetação nativa na Bahia?", general_chats(:with_messages).display_title
  end

  test "display_title falls back to the first user message when there is no title yet" do
    general_chat = general_chats(:with_messages)
    general_chat.update_column(:title, nil)

    assert_equal "Qual norma regula supressão de vegetação nativa na Bahia?", general_chat.display_title
  end

  test "display_title truncates a long first message" do
    general_chat = general_chats(:empty_chat)
    general_chat.messages.create!(role: "user", content: "a" * 100, internal: false)

    assert_equal 60, general_chat.display_title.length
  end

  test "display_title falls back to a generic label when there is no title nor any message" do
    assert_equal "Nova consulta", general_chats(:empty_chat).display_title
  end

  test "display_title ignores internal messages when looking for the first user message" do
    general_chat = general_chats(:empty_chat)
    general_chat.messages.create!(role: "user", content: "mensagem interna", internal: true)

    assert_equal "Nova consulta", general_chat.display_title
  end

  test "belongs to a user, and is destroyed when the user is destroyed" do
    user = User.create!(name: "Descartável", email_address: "descartavel@example.com", password: "password")
    general_chat = user.general_chats.create!

    assert_difference "GeneralChat.count", -1 do
      user.destroy!
    end
    assert_not GeneralChat.exists?(general_chat.id)
  end
end
