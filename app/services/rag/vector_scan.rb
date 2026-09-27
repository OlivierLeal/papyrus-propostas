module Rag
  # Busca vetorial COM FILTRO no índice HNSW (2026-09-27, achado avaliando o RAG: a busca
  # "composição de equipe RAP hidrelétrica" nas propostas da Papyrus devolvia ZERO resultados com
  # 6.879 trechos candidatos).
  #
  # O HNSW é aproximado: por padrão ele devolve os ~40 vizinhos mais próximos do acervo INTEIRO
  # (hnsw.ef_search = 40) e só DEPOIS o Postgres aplica o WHERE. Filtrando por papel (voz da
  # Papyrus = ~11% dos 71 mil trechos), por cliente ou sem boilerplate, quase nunca sobra algum
  # dos 40 — a busca voltava vazia ou com 1-2 trechos. Com o acervo pequeno (~400 documentos)
  # isso não aparecia; com 3 mil documentos, quebrou em silêncio.
  #
  # pgvector >= 0.8 tem a correção certa: `hnsw.iterative_scan` continua varrendo o índice até
  # achar `limit` linhas que passam no filtro. strict_order mantém a ordem exata por distância.
  # Versão mais antiga: sobe o ef_search, que ameniza sem resolver.
  module VectorScan
    EF_SEARCH = 400

    module_function

    # O bloco precisa MATERIALIZAR o resultado (to_a/map) aqui dentro — o SET LOCAL só vale
    # nesta transação.
    def with_filtered_scan
      ActiveRecord::Base.transaction(requires_new: true) do
        connection = ActiveRecord::Base.connection
        connection.execute("SET LOCAL hnsw.ef_search = #{EF_SEARCH}")
        connection.execute("SET LOCAL hnsw.iterative_scan = strict_order") if iterative_scan_supported?
        yield
      end
    end

    def iterative_scan_supported?
      return @iterative_scan_supported unless @iterative_scan_supported.nil?

      version = ActiveRecord::Base.connection.select_value("SELECT extversion FROM pg_extension WHERE extname = 'vector'")
      @iterative_scan_supported = version.present? && Gem::Version.new(version) >= Gem::Version.new("0.8.0")
    end
  end
end
