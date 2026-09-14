# Distância/duração RODOVIÁRIA real entre dois pontos via Mapbox Directions API — mesma conta/
# env var do MapboxStaticMap (CLAUDE.md seção 12: ENV["MAPBOX_API_KEY"], nunca hardcoded), mesmo
# padrão de tolerância a falha: sem chave, erro de rede ou sem rota encontrada, devolve nil em vez
# de levantar. Quem chama (ProjectPricing#suggest_logistics!) cai pro fallback de linha reta
# (Rag::CorpusFloor não tem nada a ver — aqui é RGeo#distance × fator de estrada) nesse caso.
module Logistics
  class MapboxDirections
    Result = Struct.new(:distance_km, :duration_hours, keyword_init: true)

    def self.available?
      ENV["MAPBOX_API_KEY"].present?
    end

    # origin/destination: pontos RGeo (respondem a .x/.y como lon/lat) — mesma factory esférica
    # usada em KmzGeometryExtractor/Logistics::DestinationResolver.
    def initialize(origin, destination)
      @origin = origin
      @destination = destination
    end

    def fetch
      return nil unless self.class.available?

      response = Net::HTTP.get_response(URI(url))
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("MapboxDirections: HTTP #{response.code}")
        return nil
      end

      route = JSON.parse(response.body)["routes"]&.first
      return nil unless route

      Result.new(distance_km: route["distance"] / 1000.0, duration_hours: route["duration"] / 3600.0)
    rescue StandardError => e
      Rails.logger.error("MapboxDirections failed: #{e.class} #{e.message}")
      nil
    end

    private
      def url
        "https://api.mapbox.com/directions/v5/mapbox/driving/" \
        "#{@origin.x},#{@origin.y};#{@destination.x},#{@destination.y}" \
        "?overview=false&access_token=#{ENV['MAPBOX_API_KEY']}"
      end
  end
end
