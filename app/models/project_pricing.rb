class ProjectPricing < ApplicationRecord
  belongs_to :proposal
  has_many :proposal_professionals, dependent: :destroy
  accepts_nested_attributes_for :proposal_professionals, update_only: true

  # Cronograma (Gantt no .docx, ver ScheduleItem/ScheduleTableBuilder) — não entra no cálculo de
  # preço, só é lido na hora de gerar o documento.
  has_many :schedule_items, -> { order(:position) }, dependent: :destroy
  accepts_nested_attributes_for :schedule_items, update_only: true

  validates :bdi, :tax_multiplier, presence: true, numericality: { greater_than: 0 }
  validates :distance_km, :rental_per_day, :meal_per_person_per_day, :fuel_total,
            :fuel_price_per_liter, :vehicle_consumption_km_per_liter, :lodging_per_person_per_night,
            presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :logistics_days, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :vehicles_count, presence: true, numericality: { greater_than_or_equal_to: 1 }

  # Nº de passageiros por veículo de campo — regra simples pra estimar quantos carros a equipe
  # precisa (ver #suggested_vehicles_count), não um cadastro de frota/veículo por tipo.
  PASSENGERS_PER_VEHICLE = 4

  # Acima de um destes, a viagem de carro deixa de fazer sentido — suggest_logistics! não calcula
  # combustível (fica 0, o consultor decide) e a Tela de Precificação avisa que sugere
  # deslocamento aéreo (passagem+locação no destino vão em Custos Externos, campo livre já
  # existente).
  LONG_DISTANCE_KM_THRESHOLD = 800
  LONG_DISTANCE_HOURS_THRESHOLD = 10

  # Fallback de linha reta quando a Mapbox Directions não responde (sem chave, erro de rede, sem
  # rota) — ROAD_FACTOR aproxima a distância real de estrada a partir da geodésica; velocidade
  # média estima a duração no mesmo fallback.
  ROAD_FACTOR = 1.3
  AVERAGE_SPEED_KMH = 70.0

  def professionals_total
    proposal_professionals.sum(&:subtotal)
  end

  # C4 = logística = (hospedagem/pessoa/noite + alimentação/pessoa/dia) × pessoas em campo × dias
  # + aluguel/veículo/dia × nº de veículos × dias + combustível (2026-09: hospedagem/alimentação
  # passam a ser POR PESSOA, aluguel continua por VEÍCULO — ver CLAUDE.md seção 5).
  def logistics_total
    people = field_professionals_count
    lodging = lodging_per_person_per_night * people * logistics_days
    meals = meal_per_person_per_day * people * logistics_days
    rental = rental_per_day * vehicles_count * logistics_days
    lodging + meals + rental + fuel_total
  end

  # Nº de profissionais desta proposta que vão a campo (hours_field > 0) — mínimo 1 pra nunca
  # zerar hospedagem/alimentação/veículo quando há dias de campo mas a equipe ainda não foi
  # detalhada (ex.: logo depois de build_from_template!, antes do consultor ajustar horas).
  def field_professionals_count
    n = proposal_professionals.where("hours_field > 0").count
    n.zero? ? 1 : n
  end

  def long_distance?
    distance_km.to_f > LONG_DISTANCE_KM_THRESHOLD || travel_hours.to_f > LONG_DISTANCE_HOURS_THRESHOLD
  end

  # Calcula distância/duração até o projeto (Logistics::DestinationResolver +
  # Logistics::MapboxDirections, com fallback de linha reta), e a partir disso sugere nº de
  # veículos e combustível — nunca a hospedagem/alimentação/aluguel por dia, que continuam
  # digitados pelo consultor (só passam a ser multiplicados certo, ver #logistics_total). Roda
  # uma vez na criação da proposta (Conversation#ensure_proposal!) e pode ser refeita a qualquer
  # momento (botão "Recalcular logística" na Tela de Precificação, ou
  # GenerateProposalDocumentTool#ensure_logistics_suggested! quando o KMZ ainda não tinha
  # terminado na 1ª tentativa). Só Ruby + HTTP — nunca IA, preço continua sempre determinístico
  # (CLAUDE.md seção 1).
  def suggest_logistics!
    destination = Logistics::DestinationResolver.call(proposal)
    return unless destination

    result = Logistics::MapboxDirections.new(Logistics::DestinationResolver::PAPYRUS_HQ_POINT, destination).fetch ||
      straight_line_estimate(destination)
    self.distance_km = result.distance_km.round(1)
    self.travel_hours = result.duration_hours.round(1)
    self.vehicles_count = suggested_vehicles_count
    self.fuel_total = long_distance? ? 0 : estimated_fuel_total
    save!
    recalculate!
  rescue StandardError => e
    Rails.logger.error("suggest_logistics! falhou para project_pricing #{id}: #{e.class} #{e.message}")
  end

  # C5 = custos externos (ARTs, terceiros: fauna, flora, drone) — lançados manualmente por proposta
  def external_costs_total
    external_costs.sum { |item| item["value"].to_f }
  end

  # C6 = TOTAL = Σ profissionais + logística + externos
  def recalculate!
    # Usa a mesma lista de objetos pra calcular, salvar e somar — carregar a associação de novo
    # (proposal_professionals.sum) logo após o save arriscaria pegar um cache desatualizado sem
    # os subtotais recém-calculados, dependendo do que já tinha sido carregado antes na request.
    lines = proposal_professionals.includes(:professional).to_a
    lines.each { |pp| pp.recalculate_subtotal(bdi: bdi, tax_multiplier: tax_multiplier) }
    ActiveRecord::Base.transaction do
      lines.each(&:save!)
      update!(total_value: (lines.sum(&:subtotal) + logistics_total + external_costs_total).round(2))
    end
  end

  def payment_schedule_amounts
    payment_schedule.map do |item|
      item.merge("amount" => (total_value * item["percentage"].to_f / 100).round(2))
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
    def suggested_vehicles_count
      (field_professionals_count / PASSENGERS_PER_VEHICLE.to_f).ceil
    end

    # Ida e volta, uma vez, por veículo (convoy viaja junto — cada veículo roda o mesmo trajeto).
    def estimated_fuel_total
      ((distance_km * 2 * vehicles_count) / vehicle_consumption_km_per_liter) * fuel_price_per_liter
    end

    def straight_line_estimate(destination)
      distance_km = Logistics::DestinationResolver::PAPYRUS_HQ_POINT.distance(destination) / 1000.0 * ROAD_FACTOR
      Logistics::MapboxDirections::Result.new(distance_km: distance_km, duration_hours: distance_km / AVERAGE_SPEED_KMH)
    end
end
