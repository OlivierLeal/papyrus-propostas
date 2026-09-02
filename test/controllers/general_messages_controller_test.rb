require "test_helper"

class GeneralMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
    @general_chat = general_chats(:with_messages)
  end

  test "create persists the user message, broadcasts it and enqueues the response job" do
    assert_enqueued_with(job: RespondToGeneralChatMessageJob) do
      assert_difference "@general_chat.messages.count", 1 do
        post general_chat_general_messages_path(@general_chat), params: { content: "Isso vale pra RJ também?" }
      end
    end

    message = @general_chat.messages.order(:created_at).last
    assert_equal "user", message.role
    assert_equal "Isso vale pra RJ também?", message.content
  end

  test "create does nothing for blank content" do
    assert_no_enqueued_jobs(only: RespondToGeneralChatMessageJob) do
      assert_no_difference "@general_chat.messages.count" do
        post general_chat_general_messages_path(@general_chat), params: { content: "   " }
      end
    end
  end

  test "create 404s for a general chat belonging to another user" do
    other_chat = users(:two).general_chats.create!

    post general_chat_general_messages_path(other_chat), params: { content: "oi" }
    assert_response :not_found
  end

  test "create attaches an uploaded document with kind document, alongside the consultant's text" do
    document = fixture_file_upload("tr_sample.pdf", "application/pdf")

    assert_enqueued_with(job: RespondToGeneralChatMessageJob) do
      post general_chat_general_messages_path(@general_chat), params: { content: "o que você acha disso?", documents: [ document ] }
    end

    message = @general_chat.messages.order(:created_at).last
    assert_equal "o que você acha disso?", message.content
    assert_equal 1, message.attachments.count
    assert_equal "document", message.attachments.first.blob.metadata["kind"]
  end

  test "create works with a document and no text, defaulting the message content to the filename" do
    document = fixture_file_upload("tr_sample.pdf", "application/pdf")

    assert_difference "@general_chat.messages.count", 1 do
      post general_chat_general_messages_path(@general_chat), params: { documents: [ document ] }
    end

    message = @general_chat.messages.order(:created_at).last
    assert_match "tr_sample.pdf", message.content
    assert_equal 1, message.attachments.count
  end
end
