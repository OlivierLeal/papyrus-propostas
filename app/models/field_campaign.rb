# Um campo (ida a campo) de um item — mesma conta da planilha da Papyrus (26098_Newave, blocos
# "Logística Campo – Físico/Sócio/Arqueologia"), conferida linha a linha contra ela:
#   dias de viagem T  = dias de campo + dias de deslocamento (ida e volta)
#   veículo           = veículos × T × diária do tipo (carro/4x4)
#   combustível       = (2 × distância + km por dia de campo × dias de campo) × veículos ÷ consumo × preço/litro
#   alimentação       = pessoas × T × valor/dia;   hospedagem = pessoas × (T − 1) × valor/noite
#   pedágios, lavagens, Uber, mateiro (dias), EPI/ASO = quantidade × valor unitário
# Os valores unitários são os da proposta (ProjectPricing). O custo aqui é DIRETO; o item aplica
# BDI × impostos. Mudou a fórmula? Mude também em pricing_preview_controller.js.
class FieldCampaign < ApplicationRecord
  VEHICLE_TYPES = { "carro" => "Carro", "4x4" => "4x4" }.freeze

  belongs_to :pricing_item

  validates :description, presence: true
  validates :vehicle_type, inclusion: { in: VEHICLE_TYPES.keys }
  validates :people, :vehicles, :tolls, :washes, :uber_trips, :epi_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :days, :travel_days, :mateiro_days, numericality: { greater_than_or_equal_to: 0 }

  def trip_days
    days + travel_days
  end

  def km(pricing)
    pricing.distance_km * 2 + pricing.daily_km * days
  end

  def breakdown(pricing)
    rental_rate = vehicle_type == "4x4" ? pricing.rental_4x4_per_day : pricing.rental_per_day
    consumption = pricing.vehicle_consumption_km_per_liter.positive? ? pricing.vehicle_consumption_km_per_liter : 1
    {
      vehicle: vehicles * trip_days * rental_rate,
      fuel: km(pricing) * vehicles / consumption * pricing.fuel_price_per_liter,
      meals: people * trip_days * pricing.meal_per_person_per_day,
      lodging: people * [ trip_days - 1, 0 ].max * pricing.lodging_per_person_per_night,
      extras: tolls * pricing.toll_price + washes * pricing.wash_price + uber_trips * pricing.uber_price +
        mateiro_days * pricing.mateiro_per_day + epi_count * pricing.epi_price
    }
  end

  def cost(pricing)
    breakdown(pricing).values.sum
  end
end
