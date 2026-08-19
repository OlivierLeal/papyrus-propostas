# Ferramenta que a IA chama quando o consultor pede pra adicionar um custo externo (ARTs,
# terceiros: fauna, flora, drone etc.) pelo chat — mesmo campo livre que já existe na Tela de
# Precificação (ver ProposalsController#add_external_cost), só que via linguagem natural. O
# valor é sempre o que o consultor informou em texto — a IA nunca calcula nem estima nada
# (CLAUDE.md seção 1), só estrutura descrição/valor e o motor determinístico
# (ProjectPricing#recalculate!) refaz a conta.
class AddExternalCostTool < RubyLLM::Tool
  description <<~DESC
    Adiciona uma linha de custo externo (ARTs, terceiros como fauna/flora/drone etc.) na
    precificação desta proposta, quando o consultor pedir pelo chat (ex.: "adiciona ART de fauna
    no valor de 500 reais"). Use exatamente a descrição e o valor que o consultor informou — nunca
    invente, arredonde ou estime um valor que não foi dito.
  DESC

  param :descricao, desc: "Descrição do custo externo (ex.: \"ART de fauna\")"
  param :valor, type: "number", desc: "Valor em reais informado pelo consultor (ex.: 500.00)"

  def initialize(proposal:)
    super()
    @proposal = proposal
  end

  def execute(descricao:, valor:)
    return { error: "A precificação ainda não existe pra essa proposta." }.to_json unless @proposal.project_pricing
    return { error: "Esta proposta já foi aprovada — a precificação está travada." }.to_json if @proposal.status == "approved"

    descricao = descricao.to_s.strip
    valor = valor.to_f
    return { error: "Preciso de uma descrição e um valor maior que zero pra adicionar o custo." }.to_json if descricao.blank? || valor <= 0

    pricing = @proposal.project_pricing
    pricing.external_costs = pricing.external_costs + [ { "description" => descricao, "value" => valor } ]
    pricing.save!
    pricing.recalculate!

    { success: true, descricao: descricao, valor: valor, total_atualizado: pricing.total_value }.to_json
  rescue StandardError => e
    Rails.logger.error("AddExternalCostTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui adicionar o custo agora. Tente novamente em instantes." }.to_json
  end
end
