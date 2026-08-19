require "test_helper"

class MessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:one)
    @conversation = conversations(:reviewing_conversation)
  end

  test "create adds a user message, broadcasts it and enqueues RespondToMessageJob" do
    assert_enqueued_with(job: RespondToMessageJob, args: [ @conversation.id ]) do
      assert_difference "@conversation.messages.count", 1 do
        post conversation_messages_path(@conversation), params: { content: "Pode ajustar a equipe sugerida?" }
      end
    end

    assert_redirected_to @conversation
    assert @conversation.messages.where(role: "user", content: "Pode ajustar a equipe sugerida?").exists?
  end

  test "create does nothing when there is no content and no documents" do
    assert_no_enqueued_jobs(only: RespondToMessageJob) do
      assert_no_difference "@conversation.messages.count" do
        post conversation_messages_path(@conversation), params: { content: "   " }
      end
    end

    assert_redirected_to @conversation
  end

  test "create is blocked while the conversation is still processing" do
    processing_conversation = conversations(:processing_conversation)

    assert_no_enqueued_jobs(only: RespondToMessageJob) do
      post conversation_messages_path(processing_conversation), params: { content: "Oi" }
    end

    assert_redirected_to processing_conversation
    follow_redirect!
    assert_match "Aguarde o processamento", response.body
  end

  test "create responds with a turbo_stream that replaces the composer, without redirecting" do
    assert_difference "@conversation.messages.count", 1 do
      post conversation_messages_path(@conversation), params: { content: "Pode ajustar a equipe sugerida?" }, as: :turbo_stream
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/turbo-stream action="replace" target="message_composer"/, response.body)
  end

  test "create attaches uploaded documents as complementary and defaults the content" do
    doc = fixture_file_upload("comp_sample.pdf", "application/pdf")

    post conversation_messages_path(@conversation), params: { documents: [ doc ] }

    message = @conversation.messages.order(:created_at).last
    assert_includes message.content, "comp_sample.pdf"
    assert_equal "complementary", message.attachments.first.blob.metadata["kind"]
  end
end
