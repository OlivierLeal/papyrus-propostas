# Mudanças de ESTRUTURA da precificação pedidas por botão na Tela de Precificação (adicionar/remover
# item, campo, custo do item e empreendimento). Os botões ficam dentro do form principal com
# name="structure_action" — o que foi digitado é salvo antes (ProposalsController#update) e nada se
# perde, sem form aninhado (proibido nesta tela, ver CLAUDE.md seção 5).
#
# Ações: "add_item", "remove_item:ID", "add_campaign:ITEM", "remove_campaign:ID",
# "add_cost:ITEM", "remove_cost:ITEM:ÍNDICE", "add_enterprise", "remove_enterprise:ID".
# Devolve a âncora da tela pra voltar no lugar certo (ou nil sem ação).
class PricingStructure
  def initialize(pricing)
    @pricing = pricing
  end

  def apply(action)
    name, *ids = action.to_s.split(":")
    case name
    when "add_item" then add_item
    when "remove_item" then remove_item(ids.first)
    when "add_campaign" then add_campaign(ids.first)
    when "remove_campaign" then remove_campaign(ids.first)
    when "add_cost" then add_cost(ids.first)
    when "remove_cost" then remove_cost(ids.first, ids.second)
    when "add_enterprise" then add_enterprise
    when "remove_enterprise" then remove_enterprise(ids.first)
    end
  end

  private

    def items = @pricing.pricing_items

    def add_item
      item = items.create!(name: "Novo item", position: items.maximum(:position).to_i + 1)
      "item-#{item.id}"
    end

    # Nunca apaga o último item; a equipe do item removido vai pro primeiro que sobrar.
    def remove_item(id)
      item = items.find_by(id: id)
      return "itens" if item.nil? || items.count <= 1

      target = items.where.not(id: item.id).first
      item.proposal_professionals.update_all(pricing_item_id: target.id)
      item.destroy!
      "itens"
    end

    def add_campaign(item_id)
      item = items.find_by(id: item_id)
      return "itens" unless item

      road = @pricing.distance_km.positive?
      item.field_campaigns.create!(description: "Campo", people: 1, days: 1, vehicles: 1,
        travel_days: @pricing.default_travel_days, tolls: road ? 2 : 0, washes: 1, uber_trips: road ? 2 : 0,
        position: item.field_campaigns.maximum(:position).to_i + 1)
      "item-#{item.id}"
    end

    def remove_campaign(id)
      campaign = FieldCampaign.joins(:pricing_item).find_by(id: id, pricing_items: { project_pricing_id: @pricing.id })
      return "itens" unless campaign

      campaign.destroy!
      "item-#{campaign.pricing_item_id}"
    end

    def add_cost(item_id)
      item = items.find_by(id: item_id)
      return "itens" unless item

      item.update!(costs: item.costs + [ { "description" => "Novo custo", "quantity" => 1, "unit_value" => 0 } ])
      "item-#{item.id}"
    end

    def remove_cost(item_id, index)
      item = items.find_by(id: item_id)
      return "itens" unless item

      costs = item.costs.dup
      costs.delete_at(index.to_i)
      item.update!(costs: costs)
      "item-#{item.id}"
    end

    def add_enterprise
      @pricing.pricing_enterprises.create!(name: "Empreendimento #{@pricing.pricing_enterprises.count + 1}",
        position: @pricing.pricing_enterprises.maximum(:position).to_i + 1)
      "empreendimentos"
    end

    def remove_enterprise(id)
      @pricing.pricing_enterprises.find_by(id: id)&.destroy!
      "empreendimentos"
    end
end
