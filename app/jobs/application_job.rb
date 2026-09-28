class ApplicationJob < ActiveJob::Base
  # Enfileira só DEPOIS do commit da transação em volta (2026-09-28, proposta 43/conversa 65:
  # "não calculou quais pessoas devem ir"). O turno de chat inteiro roda dentro da transação do
  # `with_ai_lock` (Conversation#complete_with_lock); na 1ª geração pelo chat a proposta nasce ali
  # dentro, e SuggestTeamJob/SuggestScheduleJob eram enfileirados na mesma tool call. O worker
  # pegava o job antes do commit, `Proposal.find_by` não enxergava a proposta ainda e o job saía em
  # silêncio — equipe só com os fixos a 0h e sem cronograma, pra sempre. Esperar o commit é o
  # certo pra qualquer job: ele só deve ver o estado que de fato foi gravado.
  self.enqueue_after_transaction_commit = true

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
