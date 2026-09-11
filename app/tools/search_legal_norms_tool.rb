# Dá à IA acesso de consulta ao CAL (Ius Natura, sistemacal.com.br) — base de normas legais
# ambientais que a Papyrus assina, usada como referência pra fundamentar objetivo, escopo e
# referências legais da proposta (nunca decide escopo/preço sozinha, mesmo princípio do
# SearchHistoricalArchiveTool). Ver app/services/cal/.
#
# É ferramenta sob demanda, não injeção automática — buscar no CAL a cada mensagem gastaria
# contexto e tempo de rede em toda troca, inclusive nas que não têm nada a ver com legislação.
class SearchLegalNormsTool < RubyLLM::Tool
  description <<~DESC
    Busca normas legais ambientais (leis, resoluções, portarias, instruções normativas) no CAL,
    base de legislação que a Papyrus assina. Use quando precisar fundamentar uma referência legal
    específica na proposta: qual norma rege um procedimento, qual resolução exige determinado
    estudo/diagnóstico, ou confirmar o normativo por trás de uma exigência do ET/TR.

    Não é o lugar pra decidir tipo de licença ou tipo de estudo — isso já vem do que a IA extraiu
    do ET/TR desta conversa (ver achados). Use o CAL só pra citar a base legal.

    Duas formas de uso: sem "codigo_norma", busca por palavra-chave e devolve uma lista de normas
    com um resumo curto de cada uma (campo "assunto"). Com "codigo_norma" (o "codigo" de uma norma
    já encontrada numa busca anterior nesta mesma conversa), devolve o TEXTO COMPLETO do
    documento — use isso antes de afirmar o que uma norma especificamente exige, porque o resumo
    da busca não é sempre suficiente pra saber o conteúdo exato de um artigo.

    OBRIGATÓRIO: sempre que usar qualquer norma vinda desta ferramenta, cite a origem no texto da
    resposta usando o campo "referencia" que vem junto de cada resultado — informação legal sem
    fonte é indistinguível de invenção, e o consultor precisa poder conferir a norma real.
  DESC

  param :palavra_chave, desc: "O que buscar (ex.: \"licenciamento ambiental atividades médio impacto\", \"supressão de vegetação nativa\"). Não usar junto com codigo_norma.", required: false
  param :ano, desc: "Restringe ao ano de promulgação da norma, se souber", required: false
  param :codigo_norma, desc: "Código de uma norma já encontrada numa busca anterior desta conversa (ex.: \"NL7484\") — quando informado, ignora palavra_chave/ano e devolve o TEXTO COMPLETO do documento em vez de uma lista de resultados.", required: false

  LIMIT = 8
  FULL_TEXT_INSTRUCTION = "Cite a 'referencia' no corpo da resposta ao consultor ao usar este texto."

  # Lazy de propósito: Cal::Client.new (o default de Normas/Documento) levanta
  # AuthenticationError já na CONSTRUÇÃO se faltar credencial — instanciar aqui e não só na hora
  # de usar faria a ferramenta quebrar ao ser criada, não ao ser chamada.
  def initialize(normas: nil, documento: nil)
    super()
    @normas_override = normas
    @documento_override = documento
  end

  def execute(palavra_chave: nil, ano: nil, codigo_norma: nil)
    return full_text(codigo_norma) if codigo_norma.to_s.strip.present?
    return { error: "Preciso saber o que buscar no CAL, ou o código de uma norma já encontrada nesta conversa." }.to_json if palavra_chave.to_s.strip.blank?

    result = normas.search(palavra_chave: palavra_chave.to_s.strip, ano: ano.presence)

    return { resultados: [], aviso: "Nenhuma norma encontrada no CAL para essa busca." }.to_json unless result.any?

    {
      total_encontrado: result.total_itens,
      resultados: result.normas.first(LIMIT).map { |norma| present(norma) },
      instrucao: "Cite a 'referencia' de cada norma que você usar, no corpo da resposta ao consultor. " \
                 "Se precisar saber exatamente o que uma norma exige, chame de novo com codigo_norma."
    }.to_json
  rescue Cal::Client::AuthenticationError => e
    Rails.logger.error("SearchLegalNormsTool: falha de autenticação no CAL: #{e.message}")
    { error: "Não consegui entrar no CAL agora (credenciais ou sessão)." }.to_json
  rescue StandardError => e
    Rails.logger.error("SearchLegalNormsTool falhou: #{e.class} #{e.message}")
    { error: "Não consegui consultar o CAL agora." }.to_json
  end

  private

  def normas
    @normas_override || (@normas_override = Cal::Normas.new)
  end

  def documento
    @documento_override || (@documento_override = Cal::Documento.new)
  end

  # Cache-first (2026-09, CLAUDE.md seção 11.2): a mesma norma é citada em propostas diferentes
  # com frequência (legislação de licenciamento na Bahia se repete bastante) — sem isso, cada
  # conversa nova rebaixava e reprocessava do zero uma norma que outra proposta qualquer já leu.
  # `LegalNorm.find_by(codigo:)` responde sem NENHUMA chamada ao CAL quando já existe; só busca +
  # baixa de verdade na primeira vez que aquele código é pedido em qualquer conversa.
  def full_text(codigo)
    codigo = codigo.to_s.strip
    cached = LegalNorm.find_by(codigo: codigo)
    return cached_response(cached) if cached

    norma = normas.find_by_codigo(codigo)
    return { error: "Não encontrei a norma #{codigo} no CAL." }.to_json unless norma

    result = documento.fetch(norma.anexo_id)
    return {
      referencia: norma.referencia,
      aviso: "Encontrei a norma mas não consegui ler o texto do documento (pode ser um PDF escaneado, ou sem anexo)."
    }.to_json if result.nil? || result.text.blank?

    legal_norm = persist!(norma, result)
    { referencia: legal_norm.referencia, texto: legal_norm.full_text, instrucao: FULL_TEXT_INSTRUCTION }.to_json
  rescue Cal::Client::AuthenticationError => e
    Rails.logger.error("SearchLegalNormsTool: falha de autenticação no CAL: #{e.message}")
    { error: "Não consegui entrar no CAL agora (credenciais ou sessão)." }.to_json
  rescue StandardError => e
    Rails.logger.error("SearchLegalNormsTool falhou ao buscar o texto completo: #{e.class} #{e.message}")
    { error: "Não consegui ler o documento da norma agora." }.to_json
  end

  def cached_response(legal_norm)
    { referencia: legal_norm.referencia, texto: legal_norm.full_text, instrucao: FULL_TEXT_INSTRUCTION }.to_json
  end

  # Não persiste nada quando result.text vier em branco (PDF sem anexo, ou ilegível mesmo com
  # OCR) — o cache de OCR por SHA256 (Rag::Ocr) já evita repetir o custo caro nessa norma; só
  # falta se um dia o custo de rebuscar no CAL também incomodar (ver plano, "fora de escopo").
  def persist!(norma, result)
    legal_norm = LegalNorm.new(
      codigo: norma.codigo, anexo_id: norma.anexo_id, tipo_e_numero: norma.tipo_e_numero,
      orgao: norma.orgao, ambito: norma.ambito, tema: norma.tema, escopo: norma.escopo,
      assunto: norma.assunto, data_promulgacao: norma.data_promulgacao, status: norma.status,
      referencia: norma.referencia, full_text: result.text, ocr_used: result.ocr_used
    )
    legal_norm.pdf.attach(io: StringIO.new(result.pdf_bytes), filename: "#{norma.codigo}.pdf", content_type: result.content_type)

    Rag::LegalNormIndexer.new(legal_norm, result.text).call!
  end

  def present(norma)
    {
      codigo: norma.codigo,
      norma: norma.tipo_e_numero,
      orgao: norma.orgao,
      ambito: norma.ambito,
      tema: norma.tema,
      assunto: norma.assunto,
      data_promulgacao: norma.data_promulgacao&.strftime("%d/%m/%Y"),
      status: norma.status,
      referencia: norma.referencia
    }.compact
  end
end
