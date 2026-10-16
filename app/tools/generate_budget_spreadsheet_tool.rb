# Planilha orçamentária da Papyrus montada do zero a partir da precificação (Spreadsheets::
# BudgetBuilder) — conversa 79, 2026-10-16: o consultor pediu "uma planilha do zero, não precisa
# obedecer modelo" e a IA só sabia preencher planilha anexada (respondeu que não dava e pediu pra
# ele montar um modelo, que depois saiu em branco). Sem IA: roda síncrono dentro da tool call.
class GenerateBudgetSpreadsheetTool < RubyLLM::Tool
  description <<~DESC
    Gera a PLANILHA ORÇAMENTÁRIA da Papyrus (.xlsx) desta proposta, do zero, com os custos da Tela
    de Precificação em fórmulas: horas-homem e diárias de cada profissional (quantidade × valor),
    logística de cada campo (veículo, combustível, alimentação, hospedagem…), custos dos itens, BDI
    e impostos em células editáveis (mudou, o preço recalcula), custos externos e terceirizados, e o
    desembolso. Use quando o consultor pedir a planilha orçamentária/de custos/composição de preço
    SEM mandar um modelo do cliente (com modelo anexado, use fill_client_spreadsheet). Não precisa
    de anexo nenhum.
  DESC

  def initialize(proposal:)
    super()
    @proposal = proposal
  end

  def execute
    pricing = @proposal.project_pricing
    return { error: "A precificação ainda não existe pra essa proposta — abra a Tela de Precificação primeiro." }.to_json unless pricing

    result = Spreadsheets::BudgetBuilder.new(@proposal).call
    filename = @proposal.budget_spreadsheet_filename
    @proposal.generated_documents.attach(
      io: StringIO.new(result.bytes), filename: filename,
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      metadata: { kind: "budget_spreadsheet", version: @proposal.version, description: "Planilha orçamentária" }
    )

    message = "Gerada a planilha #{filename}, com o total de R$ #{format('%.2f', result.total)}."
    message += " Diferença de R$ #{format('%.2f', result.difference.abs)} para o preço da proposta, de arredondamento (o motor arredonda linha a linha)." unless result.difference.zero?
    message += " BDI e impostos ficam nas células amarelas do topo da aba Orçamento: alterando, o preço e o desembolso recalculam (na proposta não muda nada — o preço oficial continua o da Tela de Precificação)."
    { success: true, version: @proposal.version, filenames: [ filename ], message: message }.to_json
  rescue StandardError => e
    Rails.logger.error("GenerateBudgetSpreadsheetTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui gerar a planilha agora. Tente novamente em instantes." }.to_json
  end
end
