require "test_helper"

class GeneralMessageTest < ActiveSupport::TestCase
  setup do
    @general_chat = general_chats(:with_messages)
  end

  teardown do
    Current.session = nil
  end

  # Mesmo motivo de MessageTest — ver Message#assign_current_user / GeneralMessage#
  # assign_current_user. GeneralChat é sempre privado a 1 consultor, mas o dado é guardado por
  # consistência mesmo assim (não muda o que aparece na tela deste chat).
  test "a user-role message created within a request records Current.user automatically" do
    Current.session = users(:one).sessions.create!

    message = @general_chat.messages.create!(role: "user", content: "Pergunta qualquer")

    assert_equal users(:one), message.user
  end

  test "a message that is not role user never gets a user, even with Current.user set" do
    Current.session = users(:one).sessions.create!

    message = @general_chat.messages.create!(role: "assistant", content: "Resposta da IA")

    assert_nil message.user
  end

  test "a user-role message created outside a request (no Current.user) stays without a user" do
    Current.session = nil

    message = @general_chat.messages.create!(role: "user", content: "Instrução interna", internal: true)

    assert_nil message.user
  end
end
