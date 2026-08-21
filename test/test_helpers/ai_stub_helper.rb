# Os jobs sempre re-buscam a conversa do banco (Conversation.find), então um stub de instância
# do Minitest (`conversation.stub(:complete, ...)`) não pega — precisa redefinir o método na
# CLASSE pra valer pra qualquer instância. Sem isso os testes chamariam a API de verdade (Bedrock).
module AiStubHelper
  # responses: uma string (repetida em toda chamada) ou um array (consumido em ordem; a última
  # entrada repete se a IA for chamada mais vezes do que itens fornecidos).
  def stub_ai_complete(responses)
    queue = Array(responses).dup
    original_method = Conversation.instance_method(:complete)

    Conversation.define_method(:complete) do
      content = queue.size > 1 ? queue.shift : queue.first
      messages.create!(role: "assistant", content: content)
    end

    yield
  ensure
    Conversation.define_method(:complete, original_method)
  end

  # Pra testar caminhos de erro (rate limit, falha de rede etc.) sem depender da API de verdade.
  def stub_ai_error(error_class = RubyLLM::Error)
    original_method = Conversation.instance_method(:complete)

    Conversation.define_method(:complete) do
      raise error_class, "erro simulado em teste"
    end

    yield
  ensure
    Conversation.define_method(:complete, original_method)
  end
end

# O pipeline de RAG (Rag::DocumentClassifier) roda offline, fora de qualquer Conversation, e
# por isso chama RubyLLM.chat direto — redefinir Conversation#complete não intercepta esse
# caminho. Mesma técnica, um nível acima.
module RagAiStubHelper
  def stub_rag_chat(response)
    with_stubbed_chat(->(*) { FakeChat.new(response) }) { yield }
  end

  def stub_rag_chat_error(error_class = RubyLLM::Error)
    with_stubbed_chat(->(*) { raise error_class, "erro simulado em teste" }) { yield }
  end

  private

  def with_stubbed_chat(behavior)
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |*args, **kwargs| behavior.call(*args, **kwargs) }
    yield
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end

  FakeChat = Struct.new(:response) do
    def ask(_prompt) = Struct.new(:content).new(response)
  end
end
