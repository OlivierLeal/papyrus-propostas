require "net/http"
require "json"

module WebSearch
  # Cliente HTTP pro Tavily (tavily.com) — motor de busca desenhado pra agentes de IA, devolve
  # {título, url, trecho} já prontos em vez de HTML de página de resultados pra raspar. Escolhido
  # em vez de Google/Bing porque não exige criar um "mecanismo de busca programável" nem parsear
  # SERP — é uma API REST de um endpoint só.
  #
  # 2026-09: até aqui a IA deste sistema nunca teve NENHUM acesso à internet — achado ao vivo
  # quando um consultor perguntou sobre um procedimento municipal (Teresina/PI) que não está nem
  # no CAL (só legislação estadual/federal, ver app/services/cal/) nem no acervo histórico, e a
  # IA respondeu corretamente "não tenho acesso à internet" (nenhuma tool de busca existia).
  # `WebSearchTool` é o que passa a dar esse acesso, sob controle e com citação obrigatória.
  class Client
    BASE_URL = "https://api.tavily.com/search"
    MAX_RESULTS = 10

    class AuthenticationError < StandardError; end
    class RequestError < StandardError; end

    Result = Data.define(:title, :url, :content)

    def initialize(api_key: ENV.fetch("TAVILY_API_KEY", nil))
      raise AuthenticationError, "TAVILY_API_KEY não configurado" if api_key.blank?

      @api_key = api_key
    end

    def self.configured?
      ENV["TAVILY_API_KEY"].present?
    end

    # `max_results` limitado ao teto do próprio Tavily — pedir mais não aumenta o retorno, só o
    # risco de a IA pedir mais do que precisa "pra garantir".
    def search(query, max_results: 5)
      uri = URI(BASE_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = {
        api_key: @api_key,
        query: query,
        max_results: max_results.to_i.clamp(1, MAX_RESULTS),
        search_depth: "basic"
      }.to_json

      response = http.request(request)
      raise AuthenticationError, "Tavily recusou a chave de API (401)" if response.code.to_i == 401
      raise RequestError, "Tavily respondeu #{response.code}: #{response.body}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      Array(parsed["results"]).map { |r| Result.new(title: r["title"], url: r["url"], content: r["content"]) }
    end
  end
end
