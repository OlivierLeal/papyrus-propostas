# Registra a resposta que o consultor deu NO CHAT a uma pendência aberta (ver ProjectIssue) — sem
# isso ele teria que repetir a mesma resposta no card. Só resposta de verdade: "seguir sem
# resposta" é sempre decisão humana no card, com motivo escrito.
class AnswerPendingIssueTool < RubyLLM::Tool
  description <<~DESC
    Registra a resposta do consultor a uma pendência aberta, quando ele RESPONDEU a pergunta aqui no
    chat. "resposta" é o conteúdo que ELE disse (pode resumir, nunca completar com suposição sua).
    NÃO use quando ele só pede pra gerar, pular ou "deixa pra depois" sem responder — aí diga que ele
    pode liberar no card da pendência com "Seguir sem resposta", escrevendo o motivo.
  DESC

  param :pendencia_id, type: "integer", desc: "Id da pendência (aparece no estado da proposta como #N)"
  param :resposta, desc: "A resposta do consultor"

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(pendencia_id:, resposta:)
    issue = @conversation.project_issues.open.find_by(id: pendencia_id)
    return { error: "Não há pendência aberta com esse id." }.to_json unless issue

    author = @conversation.messages.where(role: "user", internal: false).where.not(user_id: nil).order(:id).last&.user
    return { error: "Resposta vazia." }.to_json unless issue.answer!(author, resposta)

    { success: true, pendencia: issue.question, resposta: issue.answer }.to_json
  end
end
