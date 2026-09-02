require "test_helper"
require "turbo/broadcastable/test_helper"

class RespondToGeneralChatMessageJobTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @general_chat = general_chats(:with_messages)
  end

  test "completes the chat and appends the new assistant message to the stream" do
    turbo_streams = capture_turbo_stream_broadcasts @general_chat do
      stub_general_chat_ai_complete("A Lei Estadual 10.431/2006 regula isso na Bahia.") { RespondToGeneralChatMessageJob.perform_now(@general_chat.id) }
    end
    assert_equal 2, turbo_streams.size

    assert_equal "remove", turbo_streams.first["action"]
    assert_equal "append", turbo_streams.second["action"]
    assert_includes turbo_streams.second.to_s, "10.431/2006"
  end

  test "sets the title from the first user message once it answers, when there is no title yet" do
    general_chat = general_chats(:empty_chat)
    general_chat.messages.create!(role: "user", content: "Qual o prazo de uma LP?", internal: false)

    stub_general_chat_ai_complete("Depende do órgão.") { RespondToGeneralChatMessageJob.perform_now(general_chat.id) }

    assert_equal "Qual o prazo de uma LP?", general_chat.reload.title
  end

  test "does not overwrite an existing title" do
    stub_general_chat_ai_complete("ok") { RespondToGeneralChatMessageJob.perform_now(@general_chat.id) }

    assert_equal "Qual norma regula supressão de vegetação nativa na Bahia?", @general_chat.reload.title
  end

  test "registers the historical archive tool only when there is embedded acervo, and the CAL tool only when configured" do
    with_tool_calls = without_cal_configured { capture_tool_calls { RespondToGeneralChatMessageJob.perform_now(@general_chat.id) } }
    assert_empty with_tool_calls

    historical_proposal = HistoricalProposal.create!(
      client_name: "Petrobras", filename: "proposta.docx", job_number: "25001", year: 2025,
      role: "proposta_papyrus", job_name: "25001_Petrobras", source_path: "/x", relative_path: "x",
      source_sha256: "a" * 64, chunker_version: "1", role_source: "ai", status: "ok"
    )
    HistoricalProposalChunk.create!(
      historical_proposal: historical_proposal, position: 1,
      content: "trecho", embedding: Array.new(1024, 0.01), embedded_at: Time.current
    )
    with_tool_calls = with_cal_configured { capture_tool_calls { RespondToGeneralChatMessageJob.perform_now(@general_chat.id) } }
    assert_includes with_tool_calls, SearchHistoricalArchiveTool
    assert_includes with_tool_calls, SearchLegalNormsTool
  end

  test "broadcasts a friendly error bubble and does not raise when the AI call errors out" do
    turbo_streams = capture_turbo_stream_broadcasts @general_chat do
      stub_general_chat_ai_error { RespondToGeneralChatMessageJob.perform_now(@general_chat.id) }
    end
    assert_equal 2, turbo_streams.size

    assert_equal "remove", turbo_streams.first["action"]
    assert_equal "append", turbo_streams.second["action"]
    assert_includes turbo_streams.second.to_s, "Não consegui responder"
  end

  private
    def capture_tool_calls
      with_tool_calls = []
      original_method = GeneralChat.instance_method(:with_tool)
      GeneralChat.define_method(:with_tool) { |tool| with_tool_calls << tool.class; self }

      begin
        stub_general_chat_ai_complete("ok") { yield }
      ensure
        GeneralChat.define_method(:with_tool, original_method)
      end

      with_tool_calls
    end
end
