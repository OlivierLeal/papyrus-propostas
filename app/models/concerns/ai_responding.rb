# Um turno da IA por vez em cada conversa (Conversation/GeneralChat). Sem isto, mandar mensagem
# enquanto a IA ainda respondia (ex.: "gera de novo" no meio da geração do .docx) enfileirava um
# segundo turno que, ao rodar, gerava OUTRA revisão do documento logo depois da primeira.
#
# claim_ai_turn! é atômico (UPDATE ... WHERE livre): dois envios quase simultâneos não passam os
# dois. O job libera no fim (ensure). Se o job morrer sem liberar (servidor caiu no meio), a marca
# expira sozinha em STALE_AFTER — a conversa nunca fica travada pra sempre.
module AiResponding
  extend ActiveSupport::Concern

  STALE_AFTER = 15.minutes

  def ai_responding?
    ai_responding_since.present? && ai_responding_since > STALE_AFTER.ago
  end

  def claim_ai_turn!
    now = Time.current
    claimed = self.class.where(id: id)
      .where("ai_responding_since IS NULL OR ai_responding_since < ?", STALE_AFTER.ago)
      .update_all(ai_responding_since: now) == 1
    self.ai_responding_since = now if claimed
    claimed
  end

  def release_ai_turn!
    self.class.where(id: id).update_all(ai_responding_since: nil)
    self.ai_responding_since = nil
  end
end
