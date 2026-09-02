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
    with_tool_calls = without_cal_configured { capture_tool_calls { RespondToMessageJob.perform_now(@conversation.id) } }

    # reviewing_conversation não tem proposal ainda, por isso a de custo externo fica de fora.
    # A de memória (RememberForFutureProposalsTool) vale em qualquer conversa: o consultor pode
    # corrigir a IA sobre algo reaproveitável a qualquer momento.
    assert_equal [ GenerateProposalDocumentTool, RememberForFutureProposalsTool ], with_tool_calls
  end

  test "registers both the document-generation and external-cost tools when there is a proposal" do
    conversation = conversations(:priced_conversation)

    with_tool_calls = without_cal_configured { capture_tool_calls { RespondToMessageJob.perform_now(conversation.id) } }

    assert_includes with_tool_calls, GenerateProposalDocumentTool
    assert_includes with_tool_calls, AddExternalCostTool
  end

  test "registers the CAL legal norms tool only when CAL_EMAIL/CAL_PASSWORD are configured" do
    with_tool_calls = without_cal_configured { capture_tool_calls { RespondToMessageJob.perform_now(@conversation.id) } }
    assert_not_includes with_tool_calls, SearchLegalNormsTool

    with_tool_calls = with_cal_configured { capture_tool_calls { RespondToMessageJob.perform_now(@conversation.id) } }
    assert_includes with_tool_calls, SearchLegalNormsTool
  end

  # Achado ao vivo nesta sessão: RememberForFutureProposalsTool grava uma mensagem assistant
  # PRÓPRIA pro card de aprovação, separada da resposta em texto da IA — sem broadcastar as duas,
  # o card só aparecia depois de um F5 na página.
  test "broadcasts every new visible assistant message from the turn, not just the last" do
    note = @conversation.knowledge_notes.create!(category: "escopo_metodologia", content: "Regra de teste")

    original_method = Conversation.instance_method(:complete)
    Conversation.define_method(:complete) do
      messages.create!(role: "assistant", content: { knowledge_note_id: note.id }.to_json)
      messages.create!(role: "assistant", content: "Guardei isso para você.")
    end

    turbo_streams = capture_turbo_stream_broadcasts(@conversation) { RespondToMessageJob.perform_now(@conversation.id) }

    assert_equal 3, turbo_streams.size
    assert_equal "remove", turbo_streams.first["action"]
    assert_equal [ "append", "append" ], turbo_streams[1..].map { |s| s["action"] }
    assert_includes turbo_streams[1].to_s, "Regra de teste"
    assert_includes turbo_streams[2].to_s, "Guardei isso para você."
  ensure
    Conversation.define_method(:complete, original_method)
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

  private
    def capture_tool_calls
      with_tool_calls = []
      original_method = Conversation.instance_method(:with_tool)
      Conversation.define_method(:with_tool) { |tool| with_tool_calls << tool.class; self }

      begin
        stub_ai_complete("ok") { yield }
      ensure
        Conversation.define_method(:with_tool, original_method)
      end

      with_tool_calls
    end
end
