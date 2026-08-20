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

    assert_equal [ GenerateProposalDocumentTool ], with_tool_calls # reviewing_conversation não tem proposal ainda
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
end
