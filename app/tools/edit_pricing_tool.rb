# Ferramenta que a IA chama quando o consultor pede pra TIRAR algo da precificação pelo chat
# (conversa 79, 2026-10-16: "você consegue fazer essa alteração de forma autônoma? você mesmo zera
# as pessoas e dias de campo" — a IA só sabia adicionar custo externo, tentou lançar um custo
# NEGATIVO pra "compensar" a logística duplicada e acabou mandando o consultor fazer na mão).
# Só remove o que já existe, pelos mesmos caminhos da Tela de Precificação (PricingStructure,
# ProposalsController#remove_external_cost, ProposalProfessional#removable?); o motor refaz a conta.
# Nunca escreve valor: preço continua sendo do motor (CLAUDE.md seção 1).
class EditPricingTool < RubyLLM::Tool
  ACTIONS = %w[remover_campo remover_custo_externo remover_linha_equipe].freeze

  description <<~DESC
    Remove da precificação desta proposta, quando o consultor pedir pelo chat: um campo de
    logística (acao "remover_campo", com o id do campo — "campo #ID" no estado da proposta), um
    custo externo/terceirizado (acao "remover_custo_externo", com o número dele — "custo #N") ou
    uma linha da equipe (acao "remover_linha_equipe", com o id da linha — "linha #ID"). Use quando
    o consultor disser que algo está duplicado (ex.: a logística já está inclusa no valor do
    terceirizado) ou não deve entrar. Nunca lance custo negativo pra compensar — remova a linha.
    A Diretoria/Coordenação fixa não sai da equipe (zere as horas na Tela de Precificação).
  DESC

  param :acao, desc: "remover_campo, remover_custo_externo ou remover_linha_equipe"
  param :id, type: "integer", desc: "id do campo/linha, ou número do custo externo, como aparece no estado da proposta"

  def initialize(proposal:)
    super()
    @proposal = proposal
  end

  def execute(acao:, id:)
    pricing = @proposal.project_pricing
    return { error: "A precificação ainda não existe pra essa proposta." }.to_json unless pricing
    return { error: "Esta proposta já foi aprovada — a precificação está travada. O consultor reabre na Tela de Precificação." }.to_json if @proposal.status == "approved"
    return { error: "Ação desconhecida. Use: #{ACTIONS.join(', ')}." }.to_json unless ACTIONS.include?(acao.to_s)

    removed = send(acao, pricing, id.to_i)
    return removed.to_json if removed.is_a?(Hash)

    pricing.reload.recalculate!
    { success: true, removido: removed, total_atualizado: pricing.total_value }.to_json
  rescue StandardError => e
    Rails.logger.error("EditPricingTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui alterar a precificação agora. Tente novamente em instantes." }.to_json
  end

  private
    def remover_campo(pricing, id)
      campaign = FieldCampaign.joins(:pricing_item).find_by(id: id, pricing_items: { project_pricing_id: pricing.id })
      return { error: "Não achei o campo ##{id} nesta proposta." } unless campaign

      PricingStructure.new(pricing).apply("remove_campaign:#{campaign.id}")
      "campo \"#{campaign.description}\" (#{campaign.pricing_item.name})"
    end

    def remover_custo_externo(pricing, number)
      costs = pricing.external_costs.dup
      cost = number.positive? ? costs[number - 1] : nil
      return { error: "Não achei o custo externo ##{number}." } unless cost

      costs.delete_at(number - 1)
      pricing.update!(external_costs: costs)
      "custo externo \"#{cost['description']}\" (R$ #{cost['value']})"
    end

    def remover_linha_equipe(pricing, id)
      line = pricing.proposal_professionals.includes(:professional).find_by(id: id)
      return { error: "Não achei a linha ##{id} na equipe." } unless line
      return { error: "#{line.professional.name} é da equipe fixa e não sai da equipe — zere as horas na Tela de Precificação." } unless line.removable?

      line.destroy!
      "#{line.professional.name} — #{line.deliverable_name}"
    end
end
