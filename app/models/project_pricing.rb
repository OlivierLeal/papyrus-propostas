class ProjectPricing < ApplicationRecord
  # Local do projeto informado pelo consultor (tela ou chat) — vence KMZ e ET no destino da
  # logística (Logistics::DestinationResolver).
  include MunicipalityQuery

  # Colunas do modelo antigo de logística única (2026-09-28: a logística passou a ser por campo,
  # dentro de cada item — FieldCampaign). Ficam no banco até uma migração de limpeza, depois de
  # validado em produção; o código não lê nem escreve mais nelas.
  self.ignored_columns += %w[logistics_days vehicles_count fuel_total price_breakdown]

  belongs_to :proposal
  has_many :proposal_professionals, dependent: :destroy
  accepts_nested_attributes_for :proposal_professionals, update_only: true

  # Precificação por item (2026-09-28, modelo da planilha real da Papyrus — ver PricingItem,
  # FieldCampaign, PricingEnterprise e CLAUDE.md seção 5).
  has_many :pricing_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :project_pricing
  has_many :pricing_enterprises, -> { order(:position, :id) }, dependent: :destroy
  accepts_nested_attributes_for :pricing_items, update_only: true
  accepts_nested_attributes_for :pricing_enterprises, update_only: true

  # Cronograma (Gantt no .docx, ver ScheduleItem/ScheduleTableBuilder) — não entra no cálculo de
  # preço, só é lido na hora de gerar o documento.
  has_many :schedule_items, -> { order(:position) }, dependent: :destroy
  accepts_nested_attributes_for :schedule_items, update_only: true

  COMMON_SPLITS = { "equal" => "Em partes iguais", "proportional" => "Proporcional ao valor de cada empreendimento" }.freeze
  PRICE_PRESENTATIONS = {
    "total" => "Só o preço total",
    "itens" => "Aberto por item",
    "empreendimentos" => "Por item, com total de cada empreendimento"
  }.freeze
  DEFAULT_ITEM_NAME = "Execução do serviço"
  EXTERNAL_COSTS_LABEL = "Custos externos (taxas e demais despesas)"

  validate :payment_schedule_sums_to_100, if: :will_save_change_to_payment_schedule?

  validates :bdi, :tax_multiplier, presence: true, numericality: { greater_than: 0 }
  validates :distance_km, :rental_per_day, :rental_4x4_per_day, :meal_per_person_per_day,
            :fuel_price_per_liter, :vehicle_consumption_km_per_liter, :lodging_per_person_per_night,
            :toll_price, :wash_price, :uber_price, :mateiro_per_day, :epi_price, :daily_km,
            presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :common_split, inclusion: { in: COMMON_SPLITS.keys }
  validates :price_presentation, inclusion: { in: PRICE_PRESENTATIONS.keys }

  # Acima de um destes, a viagem de carro deixa de fazer sentido — a Tela de Precificação avisa
  # que sugere deslocamento aéreo (passagem+locação no destino vão em custos do item).
  LONG_DISTANCE_KM_THRESHOLD = 800
  LONG_DISTANCE_HOURS_THRESHOLD = 10

  # Viagem de ida acima disto já consome o dia: o campo ganha 2 dias de deslocamento (ida e volta),
  # como na planilha da Papyrus (Lauro de Freitas → Ourolândia, 405 km: 1 dia de campo = 3 diárias).
  TRAVEL_DAY_HOURS = 3

  # Fallback de linha reta quando a Mapbox Directions não responde (sem chave, erro de rede, sem
  # rota) — ROAD_FACTOR aproxima a distância real de estrada a partir da geodésica; velocidade
  # média estima a duração no mesmo fallback.
  ROAD_FACTOR = 1.3
  AVERAGE_SPEED_KMH = 70.0

  # BDI × impostos — vale pra equipe, logística de campo e custos dos itens (igual à planilha).
  def multiplier
    bdi * tax_multiplier
  end

  def professionals_total
    proposal_professionals.sum(&:subtotal)
  end

  # C4 = logística dos campos de todos os itens, já com BDI × impostos (2026-09-28: antes era um
  # bloco único e sem multiplicador).
  def logistics_total
    pricing_items.sum(&:campaigns_total)
  end

  # Custos fechados dos itens (ART, subcontratado "com logística"...), com BDI × impostos.
  def item_costs_total
    pricing_items.sum(&:costs_total)
  end

  def default_travel_days
    travel_hours.to_f >= TRAVEL_DAY_HOURS ? 2 : 0
  end

  def long_distance?
    distance_km.to_f > LONG_DISTANCE_KM_THRESHOLD || travel_hours.to_f > LONG_DISTANCE_HOURS_THRESHOLD
  end

  # Item padrão pra linha de equipe sem item (adicionada pela tela, pela IA ou pelos fixos).
  def default_item
    pricing_items.first || pricing_items.create!(name: DEFAULT_ITEM_NAME, position: 0)
  end

  # Distância/duração até o projeto (Logistics::DestinationResolver + Logistics::MapboxDirections,
  # com fallback de linha reta) — base do combustível e dos dias de deslocamento dos campos. Roda
  # na criação da proposta, pelo botão "Recalcular" e em GenerateProposalDocumentTool quando o KMZ
  # terminou depois. Só Ruby + HTTP — nunca IA (CLAUDE.md seção 1).
  def suggest_logistics!
    destination = Logistics::DestinationResolver.call(proposal)
    return unless destination

    result = Logistics::Route.between(Logistics::DestinationResolver::PAPYRUS_HQ_POINT, destination)
    self.distance_km = result.distance_km.round(1)
    self.travel_hours = result.duration_hours.round(1)
    save!
    recalculate!
  rescue StandardError => e
    Rails.logger.error("suggest_logistics! falhou para project_pricing #{id}: #{e.class} #{e.message}")
  end

  # C5 = custos externos (ARTs, terceiros: fauna, flora, drone) — lançados manualmente por proposta
  def external_costs_total
    external_costs.sum { |item| item["value"].to_f }
  end

  # Partição de external_costs por `kind` (chave opcional dentro de cada item do jsonb — entradas
  # antigas, ou lançadas via chat por AddExternalCostTool, não têm essa chave e caem em
  # #other_external_costs). "Serviços Terceirizados" (2026-09, pedido do consultor: mostrar isso
  # separado do resto de Custos Externos na Tela de Precificação, campo 100% manual — a IA nunca
  # marca um custo como terceirizado, só o consultor via este formulário dedicado) — mesmo
  # armazenamento de sempre (description/value), só uma tag a mais pra separar na exibição. Preço
  # (C5/#external_costs_total) não muda: soma os dois grupos igual, é só questão de UI.
  # Pares [item, índice] em vez de só os itens — a view precisa do índice na lista COMPLETA
  # (não da sublista filtrada) pra montar o link de remover (#remove_external_cost usa índice
  # posicional em `external_costs`, ver ProposalsController).
  def outsourced_costs
    external_costs.each_with_index.select { |item, _index| item["kind"] == "terceirizado" }
  end

  def other_external_costs
    external_costs.each_with_index.reject { |item, _index| item["kind"] == "terceirizado" }
  end

  # C6 = TOTAL = Σ equipe + logística dos campos + custos dos itens (tudo com BDI × impostos) +
  # custos externos (repasse, sem multiplicador).
  def recalculate!
    # Usa a mesma lista de objetos pra calcular, salvar e somar — carregar a associação de novo
    # (proposal_professionals.sum) logo após o save arriscaria pegar um cache desatualizado sem
    # os subtotais recém-calculados, dependendo do que já tinha sido carregado antes na request.
    lines = proposal_professionals.includes(:professional).to_a
    items = pricing_items.reload.includes(:field_campaigns).to_a
    factors = items.to_h { |item| [ item.id, item.days_factor ] }
    lines.each { |pp| pp.recalculate_subtotal(bdi: bdi, tax_multiplier: tax_multiplier, days_factor: factors[pp.pricing_item_id]) }
    ActiveRecord::Base.transaction do
      lines.each(&:save!)
      direct = items.sum { |item| item.campaigns_total + item.costs_total }
      update!(total_value: (lines.sum(&:subtotal) + direct + external_costs_total).round(2))
    end
  end

  # Valor de cada item (equipe + campos + custos), pro Quadro de Preço aberto e pra tela.
  # Custos externos (repasse) viram linha própria. A última linha absorve o arredondamento, então a
  # soma bate centavo a centavo com total_value.
  def price_rows
    rows = pricing_items.includes(:field_campaigns, proposal_professionals: :professional).map { |item| [ item.name, item.total.to_d ] }
    rows << [ EXTERNAL_COSTS_LABEL, external_costs_total.to_d ] if external_costs_total.positive?
    close_rounding(rows)
  end

  # Total de cada empreendimento: os próprios itens + a parte dos itens comuns (sem empreendimento,
  # e os custos externos). Rateio em partes iguais ou proporcional ao valor próprio de cada um
  # (common_split) — proporcional sem valor próprio nenhum cai pro igual. [[nome, valor], ...]
  def enterprise_totals
    enterprises = pricing_enterprises.to_a
    return [] if enterprises.empty?

    items = pricing_items.includes(:field_campaigns, proposal_professionals: :professional).to_a
    own = enterprises.to_h { |enterprise| [ enterprise.id, items.select { |i| i.pricing_enterprise_id == enterprise.id }.sum { |i| i.total.to_d } ] }
    common = items.select { |i| i.pricing_enterprise_id.nil? }.sum { |i| i.total.to_d } + external_costs_total.to_d
    own_sum = own.values.sum

    rows = enterprises.map do |enterprise|
      share = if common_split == "proportional" && own_sum.positive?
        common * own[enterprise.id] / own_sum
      else
        common / enterprises.size
      end
      [ enterprise.name, own[enterprise.id] + share ]
    end
    close_rounding(rows)
  end

  # Algum subtotal gravado não bate mais com o valor atual de hora-homem/diária do cadastro
  # (ex.: taxa preenchida em Configurações depois de a proposta existir).
  def stale_subtotals?
    factors = days_factors
    proposal_professionals.includes(:professional).any? do |pp|
      pp.subtotal != pp.expected_subtotal(bdi: bdi, tax_multiplier: tax_multiplier, days_factor: factors[pp.pricing_item_id])
    end
  end

  # PricingItem#days_factor de cada item, por id — pra passar pronto às linhas da equipe.
  def days_factors
    pricing_items.includes(:field_campaigns).to_h { |item| [ item.id, item.days_factor ] }
  end

  # Valor de cada parcela. A última absorve a diferença de arredondamento, pra soma das parcelas
  # bater centavo a centavo com o total quando os percentuais fecham 100%.
  def payment_schedule_amounts
    amounts = payment_schedule.map { |item| (total_value * item["percentage"].to_f / 100).round(2) }
    if amounts.any? && payment_percentage_total == 100
      amounts[-1] = (total_value - amounts[0..-2].sum).round(2)
    end

    payment_schedule.each_with_index.map { |item, index| item.merge("amount" => amounts[index]) }
  end

  def payment_percentage_total
    payment_schedule.sum { |item| item["percentage"].to_d }
  end

  # Parcelas editadas na Tela de Precificação (2026-09: adicionar/remover/renomear/mudar %).
  # Recebe o array vindo do form (label/percentage/date por parcela, na ordem da tela); linha sem
  # marco é descartada — é como "remover" funciona sem precisar de rota própria.
  def payment_schedule_items=(items)
    items = items.respond_to?(:values) && !items.is_a?(Array) ? items.values : Array(items)
    self.payment_schedule = items.filter_map do |item|
      item = item.to_h.stringify_keys
      label = item["label"].to_s.strip
      next if label.blank?

      percentage = item["percentage"].to_s.tr(",", ".").to_d
      { "label" => label, "percentage" => (percentage % 1).zero? ? percentage.to_i : percentage.to_f, "date" => item["date"].presence }.compact
    end
  end

  # A data de cada parcela mora dentro do próprio payment_schedule (jsonb) — não é coluna nova,
  # é mais um campo da mesma linha do cronograma, editado junto com o resto na Tela de
  # Precificação. Recebe as datas na ORDEM das parcelas, que é como o form as envia.
  def payment_dates=(dates)
    dates = Array(dates)
    self.payment_schedule = payment_schedule.each_with_index.map do |item, index|
      item.merge("date" => dates[index].presence)
    end
  end

  def payment_dates
    payment_schedule.map { |item| item["date"] }
  end

  private
    def payment_schedule_sums_to_100
      return if payment_schedule.empty? || payment_percentage_total == 100

      errors.add(:payment_schedule, "precisa somar 100% (soma atual: #{payment_percentage_total.to_s('F').sub(/\.0\z/, '').tr('.', ',')}%)")
    end

    def close_rounding(rows)
      rows = rows.map { |label, value| [ label, value.round(2) ] }
      rows[-1] = [ rows[-1][0], (total_value.to_d - rows[0..-2].sum { |_, value| value }).round(2) ] if rows.any?
      rows
    end
end
