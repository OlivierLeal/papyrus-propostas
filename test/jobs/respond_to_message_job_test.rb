require "test_helper"
require "turbo/broadcastable/test_helper"

class RespondToMessageJobTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @conversation = conversations(:reviewing_conversation)
  end

  test "completes the conversation and appends the new assistant message to the stream" do
    turbo_streams = capture_turbo_stream_broadcasts @conversation do
      stub_ai_complete("Aqui está o resumo revisado.") { RespondToMessageJob.perform_now(@conversation.id) }
    end
    assert_equal 2, turbo_streams.size

    assert_equal "remove", turbo_streams.first["action"]
    assert_equal "append", turbo_streams.second["action"]
    assert_includes turbo_streams.second.to_s, "Aqui está o resumo revisado."
  end

  test "refreshes the proposal state snapshot before completing, when there is a proposal" do
    conversation = conversations(:priced_conversation)

    stub_ai_complete("ok") { RespondToMessageJob.perform_now(conversation.id) }

    marker = conversation.messages.where(role: "user", internal: true)
      .where("content LIKE ?", "#{Conversation::PROPOSAL_STATE_MARKER}%").last
    assert marker.present?
  end

  test "registers the document-generation tool even without a proposal yet (it creates one on demand), but not the external-cost tool" do
    with_tool_calls = []
    original_method = Conversation.instance_method(:with_tool)
    Conversation.define_method(:with_tool) { |tool| with_tool_calls << tool.class; self }

    begin
      stub_ai_complete("ok") { RespondToMessageJob.perform_now(@conversation.id) }
    ensure
      Conversation.define_method(:with_tool, original_method)
    end

    # reviewing_conversation não tem proposal ainda, por isso a de custo externo fica de fora.
    # A de memória (RememberForFutureProposalsTool) vale em qualquer conversa: o consultor pode
    # corrigir a IA sobre algo reaproveitável a qualquer momento.
    assert_equal [ GenerateProposalDocumentTool, RememberForFutureProposalsTool ], with_tool_calls
  end

  test "registers both the document-generation and external-cost tools when there is a proposal" do
    conversation = conversations(:priced_conversation)
    with_tool_calls = []
    original_method = Conversation.instance_method(:with_tool)
    Conversation.define_method(:with_tool) { |tool| with_tool_calls << tool.class; self }

    begin
      stub_ai_complete("ok") { RespondToMessageJob.perform_now(conversation.id) }
    ensure
      Conversation.define_method(:with_tool, original_method)
    end

    assert_includes with_tool_calls, GenerateProposalDocumentTool
    assert_includes with_tool_calls, AddExternalCostTool
  end

  test "broadcasts a friendly error bubble and does not raise when the AI call errors out" do
    turbo_streams = capture_turbo_stream_broadcasts @conversation do
      stub_ai_error { RespondToMessageJob.perform_now(@conversation.id) }
    end
    assert_equal 2, turbo_streams.size

    assert_equal "remove", turbo_streams.first["action"]
    assert_equal "append", turbo_streams.second["action"]
    assert_includes turbo_streams.second.to_s, "Não consegui responder"
  end

  test "shows a rate-limit specific message when the AI raises RubyLLM::RateLimitError" do
    turbo_streams = capture_turbo_stream_broadcasts @conversation do
      stub_ai_error(RubyLLM::RateLimitError) { RespondToMessageJob.perform_now(@conversation.id) }
    end

    assert_includes turbo_streams.second.to_s, "limite de requisições"
  end


  # O documento que o consultor anexa no chat precisa chegar ao modelo NA MESMA rodada em que ele
  # escreve. Este teste fixa a ordem das operações do job: o snapshot do estado é gravado antes de
  # chamar a IA, e não pode roubar da mensagem do consultor a vez de carregar o anexo.
  test "o documento anexado pelo consultor continua indo para a IA depois do snapshot do estado" do
    conversation = conversations(:reviewing_conversation)
    mensagem = conversation.messages.create!(role: "user", content: "segue o projeto básico, analise")
    mensagem.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "projeto_basico.pdf",
      content_type: "application/pdf", metadata: { kind: "complementary" }
    )

    stub_ai_complete("analisado") { RespondToMessageJob.perform_now(conversation.id) }

    assert_equal [ "projeto_basico.pdf" ], mensagem.reload.to_llm.content.attachments.map(&:filename)
  end
end
