# Busca semântica no que JÁ foi guardado localmente de normas do CAL (LegalNorm/LegalNormChunk,
# ver CLAUDE.md seção 11.2) — sem bater no CAL, sem rede. Espelha SearchHistoricalArchiveTool
# (mesmo padrão: ferramenta sob demanda, citação obrigatória via "referencia"), só que sobre um
# corpus MENOR e que cresce sozinho: toda vez que search_legal_norms lê o texto completo de uma
# norma nova (codigo_norma), ela entra aqui pra sempre.
#
# Não substitui search_legal_norms — cobre só o que já foi lido antes (em QUALQUER proposta,
# legislação ambiental da Bahia se repete bastante entre projetos). Pra achar norma nova, ou pra
# ler o texto completo de uma pela primeira vez, a IA ainda precisa do CAL de verdade.
class SearchLegalNormsArchiveTool < RubyLLM::Tool
  description <<~DESC
    Busca trechos de normas legais ambientais JÁ CONSULTADAS E GUARDADAS anteriormente (em
    qualquer proposta desta Papyrus), por similaridade semântica — mais rápido que buscar no CAL
    porque não depende de rede. Use pra ver se já temos alguma legislação relevante guardada
    antes de ir ao CAL (search_legal_norms) atrás de algo novo, ou pra reencontrar rapidamente
    uma norma já lida antes (legislação de licenciamento ambiental na Bahia se repete bastante
    entre propostas diferentes).

    Cobre só o que já foi lido por completo (via search_legal_norms com codigo_norma) alguma vez
    — NÃO é o catálogo inteiro do CAL. Sem resultado aqui não significa que a norma não existe;
    ainda vale tentar search_legal_norms.

    OBRIGATÓRIO: sempre que usar qualquer norma vinda desta ferramenta, cite a origem no texto da
    resposta usando o campo "referencia" que vem junto de cada resultado.
  DESC

  param :busca, desc: "O que procurar, em linguagem natural (ex.: \"documentos exigidos para supressão de vegetação nativa na Bahia\")"

  LIMIT = 5
  # Mesmo corte de Rag::Retriever::MAX_DISTANCE — acima disso o trecho não tem relação real com
  # a pergunta, devolver assim mesmo só gasta contexto com ruído.
  MAX_DISTANCE = Rag::Retriever::MAX_DISTANCE

  def initialize(embedder: nil)
    super()
    @embedder = embedder || Rag::Embedder.new
  end

  def execute(busca:)
    return { error: "Preciso saber o que procurar na legislação já guardada." }.to_json if busca.to_s.strip.blank?

    vector = @embedder.embed_query(busca.to_s.strip)
    chunks = LegalNormChunk.embedded
      .nearest_neighbors(:embedding, vector, distance: "cosine")
      .preload(:legal_norm)
      .limit(LIMIT)
      .select { |chunk| chunk.neighbor_distance && chunk.neighbor_distance <= MAX_DISTANCE }

    return { resultados: [], aviso: "Nada guardado localmente parecido com isso — tente search_legal_norms." }.to_json if chunks.empty?

    {
      resultados: chunks.map { |chunk| present(chunk) },
      instrucao: "Cite a 'referencia' de cada trecho que você usar, no corpo da resposta ao consultor."
    }.to_json
  rescue StandardError => e
    Rails.logger.error("SearchLegalNormsArchiveTool falhou: #{e.class} #{e.message}")
    { error: "Não consegui consultar a legislação guardada agora." }.to_json
  end

  private

  def present(chunk)
    norma = chunk.legal_norm

    {
      trecho: chunk.content,
      referencia: norma.referencia,
      origem: { norma: norma.tipo_e_numero, orgao: norma.orgao, ambito: norma.ambito, assunto: norma.assunto }.compact,
      similaridade: (1 - chunk.neighbor_distance).round(4)
    }
  end
end
