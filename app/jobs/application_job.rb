class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  private
    # Manda uma pergunta pra IA sem expor a instrução (prompt de sistema do job) na
    # conversa que o consultor vê — só a resposta da IA aparece na tela de revisão/chat.
    def ask_internally(conversation, prompt, with: nil)
      instruction = conversation.create_user_message(prompt, with: with)
      instruction.update!(internal: true)
      conversation.complete
    end
end
