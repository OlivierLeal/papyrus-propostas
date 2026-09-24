require "test_helper"

module WebSearch
  class ClientTest < ActiveSupport::TestCase
    setup do
      @client = WebSearch::Client.new(api_key: "chave-de-teste")
    end

    test "requires an api key" do
      assert_raises(WebSearch::Client::AuthenticationError) { WebSearch::Client.new(api_key: nil) }
      assert_raises(WebSearch::Client::AuthenticationError) { WebSearch::Client.new(api_key: "") }
    end

    test "configured? reflects whether TAVILY_API_KEY is set" do
      without_web_search_configured { assert_not WebSearch::Client.configured? }
      with_web_search_configured { assert WebSearch::Client.configured? }
    end

    test "search posts the query and maps the results" do
      body = {
        results: [
          { title: "Portal da Prefeitura de Teresina", url: "https://teresina.pi.gov.br/licenciamento", content: "Trecho sobre dispensa..." },
          { title: "SEMAM Teresina", url: "https://semam.teresina.pi.gov.br", content: "Outro trecho." }
        ]
      }.to_json

      captured = nil
      stub_request(json_response(200, body), capture: ->(req) { captured = req }) do
        results = @client.search("licenciamento Teresina", max_results: 3)

        assert_equal 2, results.size
        assert_equal "Portal da Prefeitura de Teresina", results.first.title
        assert_equal "https://teresina.pi.gov.br/licenciamento", results.first.url
        assert_equal "Trecho sobre dispensa...", results.first.content
      end

      sent = JSON.parse(captured.body)
      assert_equal "chave-de-teste", sent["api_key"]
      assert_equal "licenciamento Teresina", sent["query"]
      assert_equal 3, sent["max_results"]
    end

    test "clamps max_results to the Tavily ceiling" do
      captured = nil
      stub_request(json_response(200, { results: [] }.to_json), capture: ->(req) { captured = req }) do
        @client.search("qualquer coisa", max_results: 999)
      end

      assert_equal WebSearch::Client::MAX_RESULTS, JSON.parse(captured.body)["max_results"]
    end

    test "returns an empty array when there are no results" do
      stub_request(json_response(200, { results: [] }.to_json)) do
        assert_equal [], @client.search("nada encontrado")
      end
    end

    test "raises AuthenticationError on a 401" do
      stub_request(json_response(401, { detail: "invalid api key" }.to_json)) do
        assert_raises(WebSearch::Client::AuthenticationError) { @client.search("qualquer coisa") }
      end
    end

    test "raises RequestError on other non-2xx responses" do
      stub_request(json_response(500, "erro interno")) do
        assert_raises(WebSearch::Client::RequestError) { @client.search("qualquer coisa") }
      end
    end

    private
      def json_response(code, body)
        klass = code == 200 ? Net::HTTPOK : (code == 401 ? Net::HTTPUnauthorized : Net::HTTPInternalServerError)
        res = klass.new("1.1", code.to_s, "")
        res.instance_variable_set(:@read, true)
        res.instance_variable_set(:@body, body)
        res
      end

      # Mesmo padrão de Cal::ClientTest#stub_requests — substitui Net::HTTP#request por uma
      # resposta pré-fabricada, sem requisição de rede de verdade, restaurando o método original
      # no fim (Net::HTTP é global, compartilhado pela suíte inteira).
      def stub_request(response, capture: nil)
        original = Net::HTTP.instance_method(:request)

        Net::HTTP.define_method(:request) do |*args|
          capture&.call(*args)
          response
        end

        yield
      ensure
        Net::HTTP.define_method(:request, original)
      end
  end
end
