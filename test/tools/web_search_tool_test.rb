require "test_helper"

class WebSearchToolTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(results: [], error: nil)
      @results = results
      @error = error
      @calls = []
    end

    def search(query, max_results:)
      @calls << { query: query, max_results: max_results }
      raise @error if @error

      @results
    end
  end

  test "returns an error when the query is blank" do
    tool = WebSearchTool.new(client: FakeClient.new)

    result = JSON.parse(tool.execute(busca: "  "))

    assert result["error"].present?
  end

  test "searches and maps each result with a citation-ready url" do
    results = [ WebSearch::Client::Result.new(title: "Portal da Prefeitura", url: "https://teresina.pi.gov.br", content: "Trecho.") ]
    client = FakeClient.new(results: results)
    tool = WebSearchTool.new(client: client)

    result = JSON.parse(tool.execute(busca: "licenciamento Teresina"))

    assert_equal 1, result["resultados"].size
    assert_equal "Portal da Prefeitura", result["resultados"].first["titulo"]
    assert_equal "https://teresina.pi.gov.br", result["resultados"].first["url"]
    assert_equal "https://teresina.pi.gov.br", result["resultados"].first["referencia"]
    assert result["instrucao"].present?
    assert_equal [ { query: "licenciamento Teresina", max_results: WebSearchTool::DEFAULT_MAX_RESULTS } ], client.calls
  end

  test "passes max_resultados through to the client" do
    tool = WebSearchTool.new(client: (client = FakeClient.new))

    tool.execute(busca: "algo", max_resultados: 2)

    assert_equal 2, client.calls.first[:max_results]
  end

  test "warns when there are no results, without raising" do
    tool = WebSearchTool.new(client: FakeClient.new(results: []))

    result = JSON.parse(tool.execute(busca: "algo bem específico"))

    assert_equal [], result["resultados"]
    assert result["aviso"].present?
  end

  test "returns a friendly error on authentication failure, without raising" do
    tool = WebSearchTool.new(client: FakeClient.new(error: WebSearch::Client::AuthenticationError.new("boom")))

    result = JSON.parse(tool.execute(busca: "algo"))

    assert result["error"].present?
  end

  test "returns a friendly error on any other failure, without raising" do
    tool = WebSearchTool.new(client: FakeClient.new(error: StandardError.new("boom")))

    result = JSON.parse(tool.execute(busca: "algo"))

    assert result["error"].present?
  end
end
