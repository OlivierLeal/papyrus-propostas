# Busca de hospedagem na Stay22 (api.stay22.com/v2/accommodations — preços vêm da Booking).
# Chave em ENV["STAY22_API_KEY"], enviada no header X-API-Key (Bearer e query param dão 401 —
# conferido ao vivo em 2026-09-29). Mesmo padrão de tolerância a falha do Mapbox: sem chave, erro
# de rede ou resposta estranha, devolve [] em vez de levantar.
#
# Achado ao testar: o raio é limitado a ~100 km do lado da Stay22 (pedir 300 km devolve o mesmo
# que 100) — por isso Lodging::Search busca também em volta das cidades vizinhas.
module Lodging
  class Stay22Client
    URL = "https://api.stay22.com/v2/accommodations".freeze
    MAX_RADIUS_M = 100_000
    PAGE_SIZE = 50

    Option = Data.define(:id, :name, :kind, :city, :price_per_night, :url, :lat, :lng)

    def self.configured?
      ENV["STAY22_API_KEY"].present?
    end

    # Preço por noite = menor preço total entre os fornecedores ÷ noites (1 adulto, 1 quarto).
    def search(lat:, lng:, radius_m:, checkin:, checkout:)
      return [] unless self.class.configured?

      uri = URI(URL)
      uri.query = URI.encode_www_form(lat: lat.round(5), lng: lng.round(5), checkin: checkin.iso8601,
        checkout: checkout.iso8601, adults: 1, rooms: 1, currency: "BRL", lang: "pt",
        pageSize: PAGE_SIZE, radius: [ radius_m.to_i, MAX_RADIUS_M ].min)
      request = Net::HTTP::Get.new(uri)
      request["X-API-Key"] = ENV["STAY22_API_KEY"]
      request["Accept"] = "application/json"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 20) do |http|
        http.request(request)
      end
      unless response.is_a?(Net::HTTPSuccess)
        Rails.logger.error("Stay22: HTTP #{response.code} #{response.body.to_s.truncate(200)}")
        return []
      end

      parse(JSON.parse(response.body))
    rescue StandardError => e
      Rails.logger.error("Stay22 failed: #{e.class} #{e.message}")
      []
    end

    private
      def parse(body)
        nights = body.dig("meta", "nights").to_i
        return [] unless nights.positive?

        Array(body["results"]).filter_map do |result|
          total = Array(result["suppliers"]&.values).filter_map { |supplier| supplier.dig("price", "total") }.min
          coordinates = result.dig("location", "coordinates") || {}
          next unless total && coordinates["lat"] && coordinates["lng"]

          Option.new(id: result["id"].to_s, name: result["name"].to_s, kind: result["type"].to_s,
            city: city_from(result.dig("location", "address")), price_per_night: (total.to_d / nights).round(2),
            url: result["url"].to_s, lat: coordinates["lat"].to_f, lng: coordinates["lng"].to_f)
        end
      end

      # Endereço vem como "Rua X, 29, Salvador Brazil, 40255-120" — a cidade é o pedaço que termina
      # em "Brazil" (com ou sem CEP depois).
      def city_from(address)
        parts = address.to_s.split(",").map(&:strip)
        city = parts.reverse.find { |part| part.match?(/\s(Brazil|Brasil)\z/i) }
        city&.sub(/\s+(Brazil|Brasil)\z/i, "")&.presence
      end
  end
end
