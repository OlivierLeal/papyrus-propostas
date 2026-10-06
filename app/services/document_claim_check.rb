# A IA às vezes ANUNCIA um documento que não gerou (2026-10, conversa 34: "Proposta regenerada com
# sucesso! PTC26020…Rev.03.docx" sem nenhuma chamada de ferramenta — o Rev.03 nunca existiu). Ao fim
# do turno (RespondToMessageJob) o sistema confere: resposta que anuncia geração sem arquivo novo (e
# sem geração esperando em segundo plano) não chega ao consultor. A IA recebe um aviso e responde de
# novo — chamando a ferramenta ou dizendo que não gerou; se insistir, o chat mostra um aviso honesto.
class DocumentClaimCheck
  REVISION = /\bRev\.?\s?(\d{2})\b/i
  # Frase de SUCESSO ("gerei", "foi gerado", "regenerada com sucesso"), nunca a negativa ("não foi gerado").
  GENERATED = /\b(?:gerei|regenerei|(?:foi|foram|est[áa]o?|ficou|ficaram)\s+(?:re)?gerad[oa]s?|(?:re)?gerad[oa]s?\s+com\s+sucesso|regenerad[oa]s?|(?:arquivo|documento|proposta)s?\s+(?:re)?gerad[oa]s?)\b/i
  NEGATED = /\bn[ãa]o\s+(?:\S+\s+){0,2}(?:re)?ger/i
  ASKED_TO_GENERATE = /\b(?:re)?ger(?:e|a|ar|ando)\b|\bnova (?:vers[ãa]o|revis[ãa]o)\b|\bemit/i
  NOT_THE_PROPOSAL = /planilh|\bxml\b|ms project/i # "gere a planilha" é outra ferramenta
  NUDGE = "[Aviso automático do sistema] Sua última resposta anunciou um documento, mas nenhum arquivo foi " \
    "gerado neste turno: você não chamou generate_proposal_document (ou ela não devolveu success). Se o " \
    "consultor pediu pra gerar, chame a ferramenta agora. Se não, responda de novo sem dizer que gerou " \
    "nada — e nunca cite arquivo ou revisão que não estejam em \"Documentos gerados\" no estado da proposta. " \
    "O consultor NÃO viu sua resposta anterior (ela foi descartada): responda como se fosse a primeira, sem pedir desculpas nem mencioná-la."
  FALLBACK = "Não gerei o documento desta vez — nenhum arquivo novo foi criado. Peça de novo pra gerar " \
    "(\"gere a proposta\"); a revisão mais recente continua sendo a que está em Documentos gerados."

  def initialize(conversation, before_message_ids, docs_before)
    @conversation = conversation
    @before_message_ids = before_message_ids
    @docs_before = docs_before
  end

  def call
    false_claims = false_claims_in_turn
    return if false_claims.empty?

    Rails.logger.warn("[DocumentClaimCheck] conversa #{@conversation.id}: anúncio de documento sem arquivo (#{false_claims.map(&:id).join(', ')}) — pedindo de novo")
    false_claims.each(&:destroy!)
    @conversation.create_user_message(NUDGE).update!(internal: true)
    # Obriga a chamada desta vez (o ruby_llm volta pra "auto" depois dela): o consultor pediu pra gerar,
    # e pedir de novo só com texto não bastou ao vivo — o modelo anunciou de novo sem chamar.
    @conversation.with_tools(choice: :generate_proposal_document)
    @conversation.complete_with_lock

    still_false = false_claims_in_turn
    return if still_false.empty?

    still_false.each(&:destroy!)
    @conversation.messages.create!(role: "assistant", content: FALLBACK, system_notice: true)
  end

  private

  # Com qualquer ferramenta chamada no turno, o que a IA diz vem de um resultado real (sucesso,
  # pendência, recusa, planilha em preenchimento) — só o turno SEM chamada nenhuma é suspeito.
  def false_claims_in_turn
    return [] if documents_changed? || generation_pending? || tool_called?

    new_texts.select { |message| false_claim?(message.content.to_s) }
  end

  # Só a resposta em texto da IA (card é JSON; aviso do sistema já é do sistema).
  def new_texts
    @conversation.messages.where(role: "assistant", internal: false, system_notice: false)
      .where.not(id: @before_message_ids).order(:id)
      .reject { |message| message.content.blank? || message.content.lstrip.start_with?("{") }
  end

  # Só quando o consultor pediu pra gerar: a resposta cita uma revisão que não existe, ou diz que gerou.
  def false_claim?(text)
    asked_to_generate? && (cites_missing_revision?(text) || (text.match?(GENERATED) && !text.match?(NEGATED)))
  end

  def cites_missing_revision?(text)
    text.scan(REVISION).flatten.any? { |revision| !existing_revisions.include?(revision) }
  end

  def existing_revisions
    @existing_revisions ||= Array(@conversation.proposal&.generated_documents&.map { |doc| doc.filename.to_s[REVISION, 1] }).compact.to_set
  end

  def asked_to_generate?
    last_user = @conversation.messages.where(role: "user", internal: false).order(:id).last
    text = last_user&.content.to_s
    text.match?(ASKED_TO_GENERATE) && !text.match?(NOT_THE_PROPOSAL)
  end

  def tool_called?
    ids = @conversation.messages.where(role: "assistant").where.not(id: @before_message_ids).select(:id)
    ToolCall.where(message_id: ids).exists?
  end

  def documents_changed?
    (@conversation.proposal&.generated_documents&.count || 0) != @docs_before
  end

  def generation_pending?
    @conversation.proposal&.reload&.pending_generation.present?
  end
end
