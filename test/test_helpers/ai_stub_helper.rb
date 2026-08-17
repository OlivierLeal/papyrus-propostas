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
