# Distância/duração rodoviária entre dois pontos RGeo: Mapbox Directions quando responde, senão
# linha reta × fator de estrada (ProjectPricing::ROAD_FACTOR/AVERAGE_SPEED_KMH). Nunca levanta.
# Usado pro trajeto sede → projeto, sede → local do campo e hospedagem → área do campo.
module Logistics
  module Route
    def self.between(origin, destination)
      MapboxDirections.new(origin, destination).fetch || straight_line(origin, destination)
    end

    def self.straight_line(origin, destination)
      distance_km = origin.distance(destination) / 1000.0 * ProjectPricing::ROAD_FACTOR
      MapboxDirections::Result.new(distance_km: distance_km, duration_hours: distance_km / ProjectPricing::AVERAGE_SPEED_KMH)
    end
  end
end
