module Cal
  # Busca de normas legais no CAL (POST /NormaLegalBdCliente/Search) — endpoint AJAX interno do
  # CAL, sem documentação oficial; parâmetros e headers descobertos reproduzindo uma busca real
  # feita pelo navegador (DevTools → Network → copiar requisição), ver seção 8/9 da investigação
  # original. Qualquer parâmetro novo precisa do mesmo processo antes de entrar aqui.
  class Normas
    SEARCH_PATH = "/NormaLegalBdCliente/Search"
    PAGE_URL = "#{Client::BASE_URL}/NormaLegalBdCliente".freeze

    Result = Data.define(:normas, :pagina_atual, :total_paginas, :total_itens) do
      def any? = normas.any?
    end

    def initialize(client: Client.new)
      @client = client
    end

    # palavra_chave: busca livre (é o que o CAL chama de "PalavraChave" — casa com texto do
    # assunto/norma). ano/assunto: filtros adicionais, opcionais. aplicavel_cliente: por padrão só
    # traz normas que o CAL já marcou como aplicáveis ao contrato da Papyrus (mesmo filtro que o
    # próprio consultor usaria navegando).
    def search(palavra_chave:, pagina: 1, ano: nil, assunto: nil, aplicavel_cliente: true)
      perform_search(palavra_chave: palavra_chave, pagina: pagina, ano: ano, assunto: assunto, aplicavel_cliente: aplicavel_cliente)
    end

    # Busca pelo código exato de uma norma já conhecida (ex.: "NL7484", devolvido em Norma#codigo
    # de uma busca anterior) — usa o filtro NormaLegalCodigos em vez de PalavraChave. Devolve nil
    # se não achar (código errado, ou norma fora do que é aplicável ao contrato da Papyrus).
    def find_by_codigo(codigo)
      perform_search(codigo: codigo.to_s, aplicavel_cliente: true).normas.first
    end

    private

    def perform_search(codigo: "", palavra_chave: "", pagina: 1, ano: nil, assunto: nil, aplicavel_cliente: true)
      response = @client.post_form(
        SEARCH_PATH,
        {
          "NormaLegalCodigos" => codigo,
          "Numero" => "",
          "PalavraChave" => palavra_chave.to_s,
          "Ano" => ano.to_s,
          "AplicavelParaClienteIusNatura" => aplicavel_cliente ? "True" : "False",
          "Assunto" => assunto.to_s,
          "TextoNormaLegal" => "",
          "EhBuscaNormaLegalDB" => "True",
          "DataPromulgacaoSuperiorA" => "",
          "DataPromulgacaoInferiorA" => "",
          "ddlFiltrosDinamico" => "",
          "PaginaAtual" => pagina.to_s,
          "X-Requested-With" => "XMLHttpRequest"
        },
        referer: PAGE_URL,
        extra_headers: { "X-Requested-With" => "XMLHttpRequest", "TabId" => "ad02" }
      )

      raise Client::RequestError, "CAL respondeu #{response.code} pra busca de normas" unless response.code.to_i == 200

      parsed = JSON.parse(response.body)
      Result.new(
        normas: Array(parsed["colecaoBdCliente"]).map { |item| Norma.from_api(item) },
        pagina_atual: parsed.dig("paginacao", "Pagina"),
        total_paginas: parsed.dig("paginacao", "TotalPaginas"),
        total_itens: parsed["TotalRows"]
      )
    end
  end
end
