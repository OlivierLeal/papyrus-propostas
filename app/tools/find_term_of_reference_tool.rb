# Procura de novo o TR do estudo (Termo de Referência do órgão) no CAL e na internet, a pedido do
# consultor. A busca automática já roda sozinha depois do resumo (FindTermOfReferenceJob); esta
# ferramenta é pra quando ele pede de novo ("procura o TR do INEMA"). Só enfileira — a busca é
# chamada de IA e nunca roda síncrona dentro de uma tool call (CLAUDE.md seção 8).
class FindTermOfReferenceTool < RubyLLM::Tool
  description <<~DESC
    Procura o Termo de Referência (TR) oficial do órgão ambiental para o estudo desta proposta, no
    CAL e na internet, quando o cliente não enviou um. Use quando o consultor pedir pra procurar o
    TR. Roda em segundo plano: se achar, aparece um card no chat pro consultor decidir se ele vai
    como Anexo I da proposta; se não achar, aparece um aviso. Diga isso ao consultor.
  DESC

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute
    if @conversation.client_term_of_reference?
      return { aviso: "O cliente já enviou o TR na Tela de Setup — é ele que vai como Anexo I." }.to_json
    end

    FindTermOfReferenceJob.perform_later(@conversation.id, force: true)
    { success: true, status: "Procurando em segundo plano; o resultado aparece no chat em instantes." }.to_json
  end
end
