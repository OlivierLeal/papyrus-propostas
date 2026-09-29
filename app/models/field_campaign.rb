# Um campo (ida a campo) de um item — mesma conta da planilha da Papyrus (26098_Newave, blocos
# "Logística Campo – Físico/Sócio/Arqueologia"), conferida linha a linha contra ela:
#   dias de viagem T  = dias de campo AJUSTADOS + dias de deslocamento (ida e volta)
#   veículo           = veículos × T × diária do tipo (carro/4x4)
#   combustível       = (2 × distância + (km por dia de campo + 2 × km até a hospedagem) × dias ajustados)
#                       × veículos ÷ consumo × preço/litro
#   alimentação       = pessoas × T × valor/dia;   hospedagem = pessoas × (T − 1) × valor/noite do campo
#   pedágios, lavagens, Uber, mateiro (dias), EPI/ASO = quantidade × valor unitário
# Os valores unitários são os da proposta (ProjectPricing). O custo aqui é DIRETO; o item aplica
# BDI × impostos. Mudou a fórmula? Mude também em pricing_preview_controller.js.
#
# Local e hospedagem por campo (2026-09-29, pedido do consultor): o campo pode ter o próprio
# município (senão usa o destino da proposta) e a hospedagem escolhida — hotel da busca na Stay22
# (Lodging::Search), alojamento/casa com valor digitado, ou fornecida pelo cliente. Hospedagem longe
# da área custa deslocamento diário: entra no combustível e, acima de meia hora por trecho, reduz as
# horas úteis da jornada de 8h e alonga os dias de campo (#effective_days) — e as diárias da equipe
# do item (ProposalProfessional#commute_extra_days).
class FieldCampaign < ApplicationRecord
  include MunicipalityQuery

  VEHICLE_TYPES = { "carro" => "Carro", "4x4" => "4x4" }.freeze
  LODGING_MODES = {
    "hotel" => "Hotel/pousada da busca",
    "alojamento" => "Alojamento, casa alugada ou outro",
    "cliente" => "Fornecida pelo cliente"
  }.freeze

  WORKDAY_HOURS = 8
  # Deslocamento até meia hora por trecho faz parte de qualquer dia de campo — não alonga nada.
  COMMUTE_TOLERANCE_HOURS = 0.5
  # Acima disto por trecho, a tela avisa pra procurar hospedagem mais perto (decisão do consultor).
  COMMUTE_WARNING_HOURS = 2
  # Mesmo com deslocamento enorme, conta pelo menos 1h útil por dia (evita divisão por zero).
  MIN_PRODUCTIVE_HOURS = 1

  belongs_to :pricing_item

  validates :description, presence: true
  validates :vehicle_type, inclusion: { in: VEHICLE_TYPES.keys }
  validates :lodging_mode, inclusion: { in: LODGING_MODES.keys }, allow_nil: true
  validates :people, :vehicles, :tolls, :washes, :uber_trips, :epi_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :days, :travel_days, :mateiro_days, :commute_km, :commute_hours, numericality: { greater_than_or_equal_to: 0 }
  validates :lodging_price_per_night, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :lodging_price_per_night, presence: { message: "da hospedagem precisa ser informado" }, if: -> { lodging_mode.in?(%w[hotel alojamento]) }
  validates :lodging_name, presence: { message: "da hospedagem precisa ser informado (ex.: casa alugada na vila)" }, if: -> { lodging_mode == "alojamento" }

  before_validation { self.lodging_mode = lodging_mode.presence }
  before_save :refresh_route!, if: :will_save_change_to_ibge_municipality_id?

  # --- Local (municipality_query: em branco usa o destino da proposta) ---

  # Ponto da área de trabalho: município do campo, ou o destino da proposta (KMZ/município).
  def area_point(pricing = pricing_item.project_pricing)
    ibge_municipality&.centroid || Logistics::DestinationResolver.call(pricing.proposal)
  end

  # A área só é um ponto de verdade quando vem do KMZ. Município sozinho (do campo, do consultor ou
  # do ET) dá o centroide, que em município grande fica longe da cidade — achado ao testar ao vivo:
  # pousada no centro de Remanso/BA a 1h12 "da área" (o centroide), alongando o campo à toa.
  def precise_area?(pricing = pricing_item.project_pricing)
    ibge_municipality.nil? && Logistics::DestinationResolver.resolve(pricing.proposal)&.source == "KMZ"
  end

  # Nome do município da área (sem UF), pra comparar com a cidade da hospedagem.
  def area_city_name(pricing = pricing_item.project_pricing)
    ibge_municipality&.name || Logistics::DestinationResolver.resolve(pricing.proposal)&.label.to_s.split("/").first
  end

  def route_distance_km(pricing)
    distance_km || pricing.distance_km
  end

  # --- Deslocamento diário até a hospedagem ---

  def daily_commute_hours
    commute_hours.to_d > COMMUTE_TOLERANCE_HOURS ? commute_hours.to_d * 2 : 0.to_d
  end

  def productive_hours
    [ WORKDAY_HOURS - daily_commute_hours, MIN_PRODUCTIVE_HOURS ].max
  end

  # Dias de campo planejados × jornada ÷ horas úteis, arredondado pra cima em dias inteiros.
  # Ex.: 5 dias com 2h por trecho → 8 − 4 = 4h úteis → 10 dias.
  def effective_days
    return days if daily_commute_hours.zero? || days.zero?

    [ (days * WORKDAY_HOURS / productive_hours).round(6).ceil.to_d, days ].max
  end

  def extra_days
    effective_days - days
  end

  # Quanto o campo cresceu (1 = nada) — ProposalProfessional usa pra alongar as diárias da equipe.
  def days_factor
    days.positive? ? effective_days / days : 1.to_d
  end

  def commute_warning?
    commute_hours.to_d > COMMUTE_WARNING_HOURS
  end

  def trip_days
    effective_days + travel_days
  end

  def nights
    [ trip_days - 1, 0 ].max
  end

  # --- Hospedagem ---

  def lodging_rate(pricing)
    case lodging_mode
    when "cliente" then 0.to_d
    when "hotel", "alojamento" then lodging_price_per_night.to_d
    else pricing.lodging_per_person_per_night
    end
  end

  # Campo com pernoite e sem hospedagem escolhida — usa o valor padrão da proposta e a tela avisa.
  def lodging_pending?
    lodging_mode.nil? && nights.positive?
  end

  def lodging_point
    KmzGeometryExtractor::FACTORY.point(lodging_lng, lodging_lat) if lodging_lat && lodging_lng
  end

  # Escolhe uma opção da última busca (Lodging::Search) e calcula o trajeto real até a área.
  def choose_lodging!(option_id, pricing = pricing_item.project_pricing)
    option = lodging_options.find { |candidate| candidate["id"] == option_id.to_s }
    return false unless option

    assign_attributes(lodging_mode: "hotel", lodging_name: option["name"], lodging_city: option["city"],
      lodging_url: option["url"], lodging_price_per_night: option["price_per_night"],
      lodging_lat: option["lat"], lodging_lng: option["lng"])
    area = area_point(pricing)
    if area.nil? || (!precise_area?(pricing) && same_city?(option["city"], area_city_name(pricing)))
      # Sem KMZ e hospedagem na própria cidade do local: não há como saber a distância até a área de
      # trabalho — fica zero e o consultor ajusta se souber.
      self.commute_km = self.commute_hours = 0
    else
      route = Logistics::Route.between(lodging_point, area)
      self.commute_km = route.distance_km.round(1)
      self.commute_hours = route.duration_hours.round(2)
    end
    save!
  end

  # --- Custo ---

  def km(pricing)
    route_distance_km(pricing) * 2 + (pricing.daily_km + commute_km.to_d * 2) * effective_days
  end

  def breakdown(pricing)
    rental_rate = vehicle_type == "4x4" ? pricing.rental_4x4_per_day : pricing.rental_per_day
    consumption = pricing.vehicle_consumption_km_per_liter.positive? ? pricing.vehicle_consumption_km_per_liter : 1
    {
      vehicle: vehicles * trip_days * rental_rate,
      fuel: km(pricing) * vehicles / consumption * pricing.fuel_price_per_liter,
      meals: people * trip_days * pricing.meal_per_person_per_day,
      lodging: people * nights * lodging_rate(pricing),
      extras: tolls * pricing.toll_price + washes * pricing.wash_price + uber_trips * pricing.uber_price +
        mateiro_days * pricing.mateiro_per_day + epi_count * pricing.epi_price
    }
  end

  def cost(pricing)
    breakdown(pricing).values.sum
  end

  private
    def same_city?(a, b)
      a.present? && b.present? && IbgeMunicipality.normalize(a) == IbgeMunicipality.normalize(b)
    end

    def municipality_query_context = " no campo #{description}"

    # Local do campo mudou: refaz a distância da sede até lá (dias de viagem sugeridos junto, se o
    # consultor não mexeu neles no mesmo envio) e descarta a busca/escolha de hotel, que era de
    # outra área. Alojamento digitado e "cliente" ficam — não dependem da busca.
    def refresh_route!
      point = ibge_municipality&.centroid
      if point
        route = Logistics::Route.between(Logistics::DestinationResolver::PAPYRUS_HQ_POINT, point)
        self.distance_km = route.distance_km.round(1)
        self.travel_hours = route.duration_hours.round(1)
      else
        self.distance_km = self.travel_hours = nil
      end
      unless will_save_change_to_travel_days?
        hours = travel_hours || pricing_item.project_pricing.travel_hours
        self.travel_days = hours.to_f >= ProjectPricing::TRAVEL_DAY_HOURS ? 2 : 0
      end
      self.lodging_options = []
      self.lodging_searched_at = nil
      self.lodging_search_note = nil
      return unless lodging_mode == "hotel"

      self.lodging_mode = self.lodging_name = self.lodging_city = self.lodging_url = nil
      self.lodging_price_per_night = self.lodging_lat = self.lodging_lng = nil
      self.commute_km = self.commute_hours = 0
    end
end
