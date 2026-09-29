# Busca de hospedagem pra um campo (FieldCampaign), em camadas — a Stay22 não passa de ~100 km de
# raio, e área remota às vezes não tem nada perto (testado: sertão da BA perto de Remanso, 0 opções
# em 30 km, 2 em 100 km):
#   1. 30 km em volta da área; se vier pouco,
#   2. 100 km (máximo da Stay22); se ainda vier pouco,
#   3. em volta das cidades entre 100 e 250 km da área (ibge_municipalities, PostGIS), em paralelo.
# Grava as opções no próprio campo (lodging_options) com a distância/tempo ESTIMADOS até a área
# (linha reta × fator de estrada — a rota real só é calculada pra opção escolhida, em
# FieldCampaign#choose_lodging!). O consultor escolhe; nada entra no preço sozinho.
module Lodging
  class Search
    NIGHTS = 3
    ENOUGH_OPTIONS = 5
    NEAR_RADIUS_M = 30_000
    CITY_RADIUS_M = 25_000
    FAR_CITIES_MIN_KM = 100
    FAR_CITIES_MAX_KM = 250
    FAR_CITIES_LIMIT = 8
    MAX_OPTIONS = 20

    def initialize(campaign, client: Stay22Client.new)
      @campaign = campaign
      @pricing = campaign.pricing_item.project_pricing
      @client = client
    end

    def call
      area = @campaign.area_point(@pricing)
      return finish([], "Sem localização da área — informe o município do campo ou envie o KMZ.") unless area
      return finish([], "Busca de hospedagem indisponível (STAY22_API_KEY não configurada).") unless Stay22Client.configured?

      options = fetch(area, NEAR_RADIUS_M)
      options = merge(options, fetch(area, Stay22Client::MAX_RADIUS_M)) if options.size < ENOUGH_OPTIONS
      options = merge(options, fetch_far_cities(area)) if options.size < ENOUGH_OPTIONS

      rows = options.map { |option| row(option, area) }
        .sort_by { |r| [ r["commute_km"], r["price_per_night"] ] }
        .first(MAX_OPTIONS)
      finish(rows, note_for(rows))
    end

    private
      def checkin
        @checkin ||= begin
          start = @pricing.schedule_papyrus_start_date
          start && start > Date.current ? start : Date.current.next_month.beginning_of_month
        end
      end

      def fetch(point, radius_m)
        @client.search(lat: point.y, lng: point.x, radius_m: radius_m, checkin: checkin, checkout: checkin + NIGHTS)
      end

      # Só HTTP dentro das threads — nada de ActiveRecord ali.
      def fetch_far_cities(area)
        cities = IbgeMunicipality.nearest_centroids(area, min_km: FAR_CITIES_MIN_KM, max_km: FAR_CITIES_MAX_KM, limit: FAR_CITIES_LIMIT)
        cities.map { |city| Thread.new { fetch(city[:point], CITY_RADIUS_M) } }.flat_map(&:value)
      end

      def merge(current, more)
        (current + more).uniq(&:id)
      end

      def row(option, area)
        point = KmzGeometryExtractor::FACTORY.point(option.lng, option.lat)
        estimate = Logistics::Route.straight_line(point, area)
        { "id" => option.id, "name" => option.name, "kind" => option.kind, "city" => option.city,
          "price_per_night" => option.price_per_night.to_f, "url" => option.url, "lat" => option.lat, "lng" => option.lng,
          "commute_km" => estimate.distance_km.round(1), "commute_hours" => estimate.duration_hours.round(2) }
      end

      def note_for(rows)
        return "Nenhuma hospedagem encontrada em até #{FAR_CITIES_MAX_KM} km da área. Use alojamento/casa alugada " \
               "(valor digitado) ou hospedagem fornecida pelo cliente." if rows.empty?

        nearest = rows.first
        if nearest["commute_hours"] > FieldCampaign::COMMUTE_WARNING_HOURS
          "A opção mais próxima fica a ~#{nearest['commute_km'].round} km (~#{format_hours(nearest['commute_hours'])} por trecho). " \
            "Vale considerar alojamento/casa alugada mais perto da área."
        elsif rows.size < ENOUGH_OPTIONS
          "Poucas opções na região (#{rows.size})."
        end
      end

      def format_hours(hours)
        whole = hours.floor
        minutes = ((hours - whole) * 60).round
        minutes.zero? ? "#{whole}h" : "#{whole}h#{minutes.to_s.rjust(2, '0')}"
      end

      def finish(rows, note)
        @campaign.update!(lodging_options: rows, lodging_searched_at: Time.current, lodging_search_note: note)
        rows
      end
  end
end
