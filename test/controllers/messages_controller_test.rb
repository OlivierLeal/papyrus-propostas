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

  # 2026-09, pedido do consultor: mais de um consultor pode acompanhar a mesma proposta (ver
  # comentário no controller sobre "outro consultor olhando a mesma proposta"), então o chat
  # precisa saber de QUEM é cada mensagem, não só "Você"/"IA".
  test "create records who sent the message" do
    post conversation_messages_path(@conversation), params: { content: "Mensagem da consultora Um" }

    message = @conversation.messages.find_by(content: "Mensagem da consultora Um")
    assert_equal users(:one), message.user
  end

  test "the user recorded follows who is actually signed in, not always the same person" do
    post conversation_messages_path(@conversation), params: { content: "Mensagem da consultora Um" }
    sign_out
    sign_in_as users(:two)

    post conversation_messages_path(@conversation), params: { content: "Mensagem do consultor Dois" }

    assert_equal users(:one), @conversation.messages.find_by(content: "Mensagem da consultora Um").user
    assert_equal users(:two), @conversation.messages.find_by(content: "Mensagem do consultor Dois").user
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

  # 2026-09, pedido do consultor: proposta criada sem KMZ no setup, ele quer jogar o arquivo no
  # chat depois e ter o mapa/análise geoespacial do mesmo jeito — antes, ProcessKmzJob só era
  # enfileirado uma vez, no setup (ConversationsController#create).
  test "create tags a .kmz upload with kind kmz (not complementary) and enqueues ProcessKmzJob" do
    kmz = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")

    assert_enqueued_with(job: ProcessKmzJob, args: [ @conversation.id ]) do
      post conversation_messages_path(@conversation), params: { documents: [ kmz ] }
    end

    message = @conversation.messages.order(:created_at).last
    assert_equal "kmz", message.attachments.first.blob.metadata["kind"]
    assert_includes message.content, "KMZ: area_sample.kmz"
  end

  test "create does not enqueue ProcessKmzJob when no kmz/kml file was sent" do
    doc = fixture_file_upload("comp_sample.pdf", "application/pdf")

    assert_no_enqueued_jobs(only: ProcessKmzJob) do
      post conversation_messages_path(@conversation), params: { documents: [ doc ] }
    end
  end

  test "create separates a kmz and a complementary document sent together, tagging each correctly" do
    kmz = fixture_file_upload("area_sample.kmz", "application/vnd.google-earth.kmz")
    doc = fixture_file_upload("comp_sample.pdf", "application/pdf")

    assert_enqueued_with(job: ProcessKmzJob, args: [ @conversation.id ]) do
      post conversation_messages_path(@conversation), params: { documents: [ kmz, doc ] }
    end

    message = @conversation.messages.order(:created_at).last
    kinds = message.attachments.map { |a| a.blob.metadata["kind"] }
    assert_equal %w[complementary kmz].sort, kinds.sort
  end
end
