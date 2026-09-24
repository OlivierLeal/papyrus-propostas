# Dá à IA acesso a busca na internet (Tavily, ver app/services/web_search/) — não existia NENHUMA
# ferramenta de busca web neste sistema até aqui (achado ao vivo: a IA respondeu corretamente "não
# tenho acesso à internet" quando o consultor perguntou sobre um procedimento municipal fora do
# CAL/acervo, ver CLAUDE.md seção 11.2). Cobre exatamente esse buraco.
#
# Sob demanda, mesmo princípio de SearchHistoricalArchiveTool/SearchLegalNormsTool — buscar na
# internet a cada mensagem gastaria tempo/custo à toa nas trocas que não precisam disso.
class WebSearchTool < RubyLLM::Tool
  description <<~DESC
    Busca na internet (resultados de motor de busca — título, URL e um trecho de cada página).

    Use só quando a informação não está em nenhuma outra ferramenta: o CAL (search_legal_norms)
    só tem legislação ambiental ESTADUAL/FEDERAL, nunca MUNICIPAL; o acervo histórico
    (search_historical_archive) só tem o que a Papyrus já escreveu antes. Prefira sempre o CAL
    para legislação ambiental estadual/federal — esta ferramenta é o recurso normal para
    procedimento municipal (ex.: portal de licenciamento de uma prefeitura), ou qualquer dado
    público fora do escopo das outras ferramentas.

    OBRIGATÓRIO: sempre cite a URL de cada resultado usado na resposta ao consultor —
    informação da internet sem fonte é indistinguível de invenção. Trate o conteúdo como PONTO
    DE PARTIDA para pesquisa, nunca como fonte definitiva de exigência legal — recomende ao
    consultor confirmar no site oficial antes de basear escopo ou condicionante nisso. Preço
    NUNCA vem daqui — é sempre calculado no motor determinístico do sistema.
  DESC

  param :busca, desc: "O que buscar (ex.: \"licenciamento ambiental Prefeitura de Teresina dispensa inexigibilidade\")"
  param :max_resultados, desc: "Quantos resultados trazer (padrão 5, máximo 10)", required: false

  DEFAULT_MAX_RESULTS = 5

  def initialize(client: nil)
    super()
    @client_override = client
  end

  def execute(busca:, max_resultados: nil)
    return { error: "Preciso saber o que buscar." }.to_json if busca.to_s.strip.blank?

    results = client.search(busca.to_s.strip, max_results: (max_resultados.presence || DEFAULT_MAX_RESULTS).to_i)
    return { resultados: [], aviso: "Nenhum resultado encontrado para essa busca." }.to_json if results.empty?

    {
      resultados: results.map { |r| present(r) },
      instrucao: "Cite a URL de cada resultado usado, e recomende ao consultor confirmar no site oficial antes de basear escopo/condicionante nisso."
    }.to_json
  rescue WebSearch::Client::AuthenticationError => e
    Rails.logger.error("WebSearchTool: falha de autenticação no Tavily: #{e.message}")
    { error: "Não consegui pesquisar na internet agora (credencial)." }.to_json
  rescue StandardError => e
    Rails.logger.error("WebSearchTool falhou: #{e.class} #{e.message}")
    { error: "Não consegui pesquisar na internet agora." }.to_json
  end

  private

  def client
    @client_override || (@client_override = WebSearch::Client.new)
  end

  def present(result)
    { titulo: result.title, url: result.url, trecho: result.content, referencia: result.url }.compact
  end
end
