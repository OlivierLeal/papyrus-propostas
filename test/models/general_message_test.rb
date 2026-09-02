require "test_helper"

class GeneralMessageTest < ActiveSupport::TestCase
  test "a message with role tool is automatically hidden from the visible chat" do
    general_chat = general_chats(:with_messages)
    message = general_chat.messages.create!(role: "tool", content: '{"resultados": []}')

    assert message.internal?
  end

  test "a message with role user or assistant is not hidden just for existing" do
    general_chat = general_chats(:with_messages)
    user_message = general_chat.messages.create!(role: "user", content: "oi")
    assistant_message = general_chat.messages.create!(role: "assistant", content: "olá")

    assert_not user_message.internal?
    assert_not assistant_message.internal?
  end

  test "to_llm content keeps the attachment on the most recent user message" do
    general_chat = general_chats(:with_messages)
    message = general_chat.create_user_message("segue o edital, analise")
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "edital.pdf", content_type: "application/pdf", metadata: { kind: "document" }
    )

    assert_equal [ "edital.pdf" ], message.to_llm.content.attachments.map(&:filename)
  end

  # Mesma proteção de Message#attachment_sources, contra o limite de 5 documentos por request
  # que a Anthropic aplica — sem isso, um documento anexado seria reenviado em TODA chamada
  # seguinte desta conversa, mesmo turnos que não têm nada a ver com ele.
  test "to_llm content excludes attachments from any user message that isn't the most recent one" do
    general_chat = general_chats(:with_messages)
    older_message = general_chat.create_user_message("segue o edital, analise")
    older_message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "edital.pdf", content_type: "application/pdf"
    )

    general_chat.create_user_message("e sobre isso, o que você acha?")

    assert_equal "segue o edital, analise", older_message.reload.to_llm.content
  end

  test "stale attachments stay fully downloadable — only what's sent to the AI changes" do
    general_chat = general_chats(:with_messages)
    older_message = general_chat.create_user_message("segue o edital, analise")
    older_message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "edital.pdf", content_type: "application/pdf"
    )

    general_chat.create_user_message("outra pergunta")

    assert older_message.reload.attachments.attached?
    assert_equal "edital.pdf", older_message.attachments.first.filename.to_s
  end
end
