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

  # Regressão do achado ao vivo na conversa 35/proposta 21 (2026-09, ver Conversation#
  # complete_with_lock): SuggestScheduleJob (via #ask_internally) podia começar a ler o
  # histórico desta conversa ENQUANTO o turno principal (RespondToMessageJob, #complete cru,
  # sem trava) ainda estava no meio do caminho — via a mensagem de tool_use do
  # generate_proposal_document sem o tool_result correspondente ainda gravado, e o Bedrock
  # rejeitava a chamada.
  test "complete_with_lock keeps a concurrent ask_internally from reading a half-written turn" do
    original_method = Conversation.instance_method(:complete)
    observed_last_message_content = nil
    main_started = false
    mutex = Mutex.new

    # A primeira chamada (turno principal) grava a mensagem de "tool_use", dorme — dando tempo da
    # outra thread tentar ler a conversa no meio do caminho — e só depois grava o "tool_result"
    # que fecha o par. Qualquer chamada seguinte (a "SuggestScheduleJob" simulada) só registra o
    # que viu como última mensagem, sem escrever nada devagar.
    Conversation.define_method(:complete) do
      is_main = mutex.synchronize { main_started ? false : (main_started = true) }
      if is_main
        messages.create!(role: "assistant", content: "tool_use")
        sleep 0.05
        messages.create!(role: "assistant", content: "tool_result")
      else
        # role: "assistant" só — messages.order(...).last sozinho pegaria a própria instrução
        # (role: "user") que #ask_internally acabou de gravar antes de chamar #complete, o que
        # sempre "passaria" mesmo sem trava nenhuma (não é isso que o teste quer provar).
        observed_last_message_content = messages.where(role: "assistant").order(:created_at).last&.content
        messages.create!(role: "assistant", content: "sugestão de cronograma")
      end
    end

    main_turn = Thread.new { Conversation.find(@conversation.id).complete_with_lock }
    sleep 0.01 # dá tempo do turno principal criar a mensagem de tool_use antes da outra thread tentar
    background_job = Thread.new { Conversation.find(@conversation.id).ask_internally("cronograma?", hide_response: true) }
    [ main_turn, background_job ].each(&:join)

    # Sem a trava, isso seria "tool_use" (a corrida de verdade); com complete_with_lock, o
    # background só entra depois do turno principal terminar de gravar as duas mensagens.
    assert_equal "tool_result", observed_last_message_content
  ensure
    Conversation.define_method(:complete, original_method)
  end
end
