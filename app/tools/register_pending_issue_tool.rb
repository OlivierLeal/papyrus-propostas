# A IA abre uma pendência que TRAVA a geração da proposta até o consultor responder ou liberar com
# motivo (ver ProjectIssue). Ela só propõe: quem trava é Conversation#generation_blockers, e o card
# no chat é a saída — nunca trava pra sempre.
class RegisterPendingIssueTool < RubyLLM::Tool
  description <<~DESC
    Registra uma PENDÊNCIA que trava a geração da proposta até o consultor responder (ou liberar
    com motivo). Use só para o que MUDA escopo, quantitativo, equipe, prazo ou preço e que só o
    consultor ou o cliente sabem responder — informação faltando ou incoerente nos documentos
    (ex.: "As bacias Potiguar e Pará-Maranhão do cronograma estão no escopo?", "As 2.994 diárias da
    PPU batem com a escala 14×14 e os 18 poços?").

    NÃO use para: divergência entre documentos que o sistema já mostrou em card; dado de cadastro
    (CNPJ, contato, e-mail — isso vira "A confirmar"); nada que o sistema calcula (equipe, horas,
    diárias sugeridas, logística, cronograma, preço); dúvida que você mesmo resolve lendo os
    documentos. Uma pergunta por chamada, direta e respondível. Depois de registrar, diga ao
    consultor que ele responde no card (ou no chat).
  DESC

  param :pergunta, desc: "A pergunta, direta e respondível, autoexplicativa (sem \"isso\", \"acima\")"
  param :impacto, desc: "O que muda na proposta conforme a resposta (1 frase)", required: false

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(pergunta:, impacto: nil)
    pergunta = pergunta.to_s.strip
    return { error: "Preciso da pergunta." }.to_json if pergunta.blank?

    if @conversation.project_issues.open.any? { |issue| same?(issue.question, pergunta) }
      return { aviso: "Essa pendência já está aberta; não registrei de novo." }.to_json
    end

    issue = @conversation.project_issues.create!(question: pergunta, impact: impacto.presence, source: "chat")
    # Card próprio (mensagem assistant), mesmo motivo do card de memória: o resultado da tool call
    # nasce oculto (Message#hide_tool_result!).
    @conversation.messages.create!(role: "assistant", content: { project_issue_id: issue.id }.to_json)
    { success: true, project_issue_id: issue.id, status: "aberta — trava a geração até o consultor responder" }.to_json
  end

  private

  def same?(a, b)
    normalize(a) == normalize(b)
  end

  def normalize(text)
    I18n.transliterate(text.to_s.downcase).gsub(/[^a-z0-9]+/, " ").strip
  end
end
