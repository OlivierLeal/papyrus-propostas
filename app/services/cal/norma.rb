module Cal
  # Uma norma legal normalizada a partir de uma linha de `colecaoBdCliente` (resposta de
  # POST /NormaLegalBdCliente/Search) — campos e formato descobertos inspecionando uma busca real
  # no CAL (ver resultado_normas.json na investigação original), não documentados pela Ius Natura.
  Norma = Data.define(
    :codigo, :tipo_e_numero, :orgao, :ambito, :tema, :escopo, :assunto,
    :data_promulgacao, :status, :aplicavel_cliente, :anexo_id
  ) do
    DOTNET_DATE = %r{\A/Date\((\d+)\)/\z}

    def self.from_api(item)
      new(
        codigo: item["Codigo"],
        tipo_e_numero: item["TipoNormaENumeroEAnoPromulgacao"].to_s.squish.presence,
        orgao: item["OrgaoNome"],
        ambito: item["AmbitoNome"],
        tema: item["TemaNome"],
        escopo: item["EscopoNome"],
        assunto: item["Assunto"],
        data_promulgacao: parse_dotnet_date(item["DataPromulgacao"]),
        status: item["DescricaoDisponivelConsulta"],
        aplicavel_cliente: item["NormaAplicavelCliente"],
        anexo_id: item["NomeAnexo"]
      )
    end

    # O CAL serializa data no formato ASP.NET AJAX clássico "/Date(ms desde epoch UTC)/", não
    # ISO 8601 — não tem como Date.parse dar conta disso sozinho.
    #
    # Sempre em UTC explícito aqui (Time.at(...).utc), nunca Time.zone.at — a data de promulgação
    # de uma norma é um FATO de calendário, não um timestamp pra mostrar na hora local do
    # consultor; converter pelo Time.zone da aplicação (Brasilia, UTC-3 desde a config de
    # 2026-09) desloca a data pro dia anterior sempre que o ms corresponder à meia-noite UTC —
    # achado ao vivo assim que Time.zone deixou de ser UTC (teste passava só por coincidência).
    def self.parse_dotnet_date(value)
      match = DOTNET_DATE.match(value.to_s)
      return nil unless match

      Time.at(match[1].to_i / 1000).utc.to_date
    end

    # Frase pronta pra citação (mesmo espírito do SearchHistoricalArchiveTool#reference_for) — o
    # consultor precisa poder conferir a norma no CAL, não só confiar no resumo da IA.
    def referencia
      partes = [ tipo_e_numero, orgao, ambito ].compact_blank
      "#{codigo} — #{partes.join(', ')} (CAL/Ius Natura)"
    end
  end
end
