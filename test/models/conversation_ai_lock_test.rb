require "test_helper"

# Precisa de conexões de banco DE VERDADE por thread (não a conexão compartilhada que os testes
# transacionais usam) pra reproduzir a corrida de verdade entre duas chamadas concorrentes de
# ask_internally — é exatamente isso que pg_advisory_xact_lock (ver Conversation#with_ai_lock)
# precisa provar que evita. Ver conversation_test.rb pros testes normais (não-concorrentes) de
# ask_internally.
class ConversationAiLockTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @conversation = Conversation.create!(user: users(:one), client_name: "Lock test", status: "setup")
  end

  teardown do
    @conversation.destroy
  end

  test "ask_internally serializes concurrent calls on the same conversation instead of letting them race" do
    original_method = Conversation.instance_method(:complete)
    # Sono proposital: sem a trava, dá tempo da outra thread criar a própria instrução no meio do
    # caminho, fazendo esta thread responder à pergunta ERRADA quando acordar — exatamente o bug
    # visto na prática (ver comentário em Conversation#ask_internally).
    Conversation.define_method(:complete) do
      sleep 0.05
      last_instruction = messages.where(role: "user").order(:created_at).last
      messages.create!(role: "assistant", content: "resposta para: #{last_instruction.content}")
    end

    threads = [
      Thread.new { Conversation.find(@conversation.id).ask_internally("Pergunta A", hide_response: true) },
      Thread.new { Conversation.find(@conversation.id).ask_internally("Pergunta B", hide_response: true) }
    ]
    threads.each(&:join)

    @conversation.reload
    instructions = @conversation.messages.where(role: "user").order(:created_at).pluck(:content)
    replies = @conversation.messages.where(role: "assistant").order(:created_at)

    assert_equal [ "Pergunta A", "Pergunta B" ], instructions.sort
    assert_equal 2, replies.count
    assert replies.all?(&:internal?), "as duas respostas deveriam ficar escondidas (hide_response: true)"

    # Cada resposta tem que corresponder à SUA PRÓPRIA pergunta — sem a trava, uma call pode
    # acordar depois que a outra já criou a instrução dela, e responder à pergunta errada.
    answered_questions = replies.map { |r| r.content.sub("resposta para: ", "") }
    assert_equal [ "Pergunta A", "Pergunta B" ], answered_questions.sort
  ensure
    Conversation.define_method(:complete, original_method)
  end
end
