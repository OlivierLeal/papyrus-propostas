require "test_helper"

# Proposta 43/conversa 65 (2026-09-28): SuggestTeamJob enfileirado de dentro do turno de chat (que
# roda numa transação) era pego pelo worker antes do commit e não achava a proposta recém-criada.
class EnqueueAfterCommitTest < ActiveJob::TestCase
  self.use_transactional_tests = false

  test "job enfileirado dentro de uma transação só entra na fila depois do commit" do
    ApplicationRecord.transaction do
      SuggestTeamJob.perform_later(0)
      assert_no_enqueued_jobs only: SuggestTeamJob
    end
    assert_enqueued_jobs 1, only: SuggestTeamJob
  end

  test "rollback descarta o job" do
    ApplicationRecord.transaction do
      SuggestTeamJob.perform_later(0)
      raise ActiveRecord::Rollback
    end
    assert_no_enqueued_jobs only: SuggestTeamJob
  end
end
