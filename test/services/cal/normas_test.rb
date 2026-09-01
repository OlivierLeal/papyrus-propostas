require "test_helper"

module Cal
  class NormasTest < ActiveSupport::TestCase
    FakeResponse = Struct.new(:code, :body)

    class FakeClient
      attr_reader :calls

      def initialize(response)
        @response = response
        @calls = []
      end

      def post_form(path, params, referer:, extra_headers:)
        @calls << { path: path, params: params, referer: referer, extra_headers: extra_headers }
        @response
      end
    end

    test "search sends the expected form params and parses the response into Norma objects" do
      payload = {
        "colecaoBdCliente" => [
          { "Codigo" => "NL1", "TipoNormaENumeroEAnoPromulgacao" => "Portaria 1/20", "OrgaoNome" => "INEMA",
            "AmbitoNome" => "Estadual", "TemaNome" => "Fauna", "EscopoNome" => "Meio Ambiente",
            "Assunto" => "Sobre fauna", "DataPromulgacao" => "/Date(1577836800000)/",
            "DescricaoDisponivelConsulta" => "Disponível para consulta", "NormaAplicavelCliente" => true,
            "NomeAnexo" => "abc-123" }
        ],
        "paginacao" => { "Pagina" => 1, "TotalPaginas" => 3 },
        "TotalRows" => 42
      }
      client = FakeClient.new(FakeResponse.new("200", payload.to_json))

      result = Cal::Normas.new(client: client).search(palavra_chave: "fauna", pagina: 1)

      call = client.calls.sole
      assert_equal "/NormaLegalBdCliente/Search", call[:path]
      assert_equal "fauna", call[:params]["PalavraChave"]
      assert_equal "True", call[:params]["AplicavelParaClienteIusNatura"]
      assert_equal "1", call[:params]["PaginaAtual"]
      assert_equal "XMLHttpRequest", call[:extra_headers]["X-Requested-With"]

      assert_equal 42, result.total_itens
      assert_equal 3, result.total_paginas
      assert result.any?
      norma = result.normas.sole
      assert_equal "NL1", norma.codigo
      assert_equal "INEMA", norma.orgao
      assert_equal Date.new(2020, 1, 1), norma.data_promulgacao
    end

    test "search sends AplicavelParaClienteIusNatura=False when aplicavel_cliente is false" do
      client = FakeClient.new(FakeResponse.new("200", { "colecaoBdCliente" => [], "paginacao" => {}, "TotalRows" => 0 }.to_json))

      Cal::Normas.new(client: client).search(palavra_chave: "x", aplicavel_cliente: false)

      assert_equal "False", client.calls.sole[:params]["AplicavelParaClienteIusNatura"]
    end

    test "search raises RequestError when the CAL responds with a non-200 status" do
      client = FakeClient.new(FakeResponse.new("500", ""))

      assert_raises(Cal::Client::RequestError) { Cal::Normas.new(client: client).search(palavra_chave: "x") }
    end

    test "result#any? is false for an empty collection" do
      client = FakeClient.new(FakeResponse.new("200", { "colecaoBdCliente" => [], "paginacao" => {}, "TotalRows" => 0 }.to_json))

      result = Cal::Normas.new(client: client).search(palavra_chave: "nada disso existe")

      assert_not result.any?
    end

    test "find_by_codigo searches by NormaLegalCodigos instead of PalavraChave and returns the first match" do
      payload = { "colecaoBdCliente" => [ { "Codigo" => "NL7484", "NomeAnexo" => "guid-1" } ], "paginacao" => {}, "TotalRows" => 1 }
      client = FakeClient.new(FakeResponse.new("200", payload.to_json))

      norma = Cal::Normas.new(client: client).find_by_codigo("NL7484")

      call = client.calls.sole
      assert_equal "NL7484", call[:params]["NormaLegalCodigos"]
      assert_equal "", call[:params]["PalavraChave"]
      assert_equal "True", call[:params]["AplicavelParaClienteIusNatura"]
      assert_equal "NL7484", norma.codigo
    end

    test "find_by_codigo returns nil when nothing matches" do
      client = FakeClient.new(FakeResponse.new("200", { "colecaoBdCliente" => [], "paginacao" => {}, "TotalRows" => 0 }.to_json))

      assert_nil Cal::Normas.new(client: client).find_by_codigo("NL0")
    end
  end
end
