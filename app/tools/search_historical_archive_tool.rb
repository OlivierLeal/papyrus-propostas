# Dá à IA acesso de consulta ao acervo histórico da Papyrus (CLAUDE.md seção 11.1) — as
# propostas, TRs e anexos técnicos de jobs anteriores, indexados por similaridade semântica.
#
# É uma ferramenta e não injeção automática de contexto de propósito: buscar no acervo a cada
# mensagem gastaria contexto do modelo em toda troca, inclusive nas que não têm nada a ver com
# histórico. Assim a IA busca quando a pergunta pede, e a consulta fica registrada na conversa.
#
# O parâmetro `fonte` existe porque o acervo NÃO é homogêneo: numa pasta de job convivem o que a
# Papyrus escreveu e o que o cliente mandou, e o documento do cliente costuma ser maior. Buscar
# tudo junto ao perguntar "como a Papyrus redige o escopo" devolveria texto da Petrobras — a IA
# aprenderia a imitar o cliente. Ver Rag::DocumentClassifier.
class SearchHistoricalArchiveTool < RubyLLM::Tool
  description <<~DESC
    Busca trechos de propostas e documentos de projetos ANTERIORES da Papyrus, por similaridade
    semântica. Use sempre que precisar saber como a Papyrus já tratou algo antes: como costuma
    redigir uma seção, que escopo aplicou num tipo de estudo, que equipe usou, que ressalvas fez,
    ou o que um cliente exigiu num projeto parecido.

    Não use para perguntas sobre os documentos DESTA proposta (ET, TR, KMZ e complementares desta
    conversa já estão no histórico). Esta ferramenta é só para o acervo de projetos passados.

    Os trechos retornados são REFERÊNCIA para escrever, nunca fonte de preço: valores de
    propostas antigas não valem para esta, quem calcula preço é o motor de precificação.

    OBRIGATÓRIO: sempre que usar qualquer informação vinda desta ferramenta, cite a origem no
    texto da resposta, usando o campo "referencia" que vem junto de cada trecho. O consultor
    precisa saber de que projeto veio cada coisa para poder conferir — informação do acervo
    apresentada sem fonte é indistinguível de invenção.
  DESC

  param :busca, desc: "O que procurar, em linguagem natural (ex.: \"escopo de diagnóstico de fauna em EIA-RIMA de eólica\")"
  param :fonte,
    desc: 'Onde procurar: "papyrus" (o que a Papyrus escreveu — padrão, use para redação e escopo), ' \
          '"cliente" (TRs, especificações e anexos técnicos recebidos de clientes) ou "tudo".',
    required: false
  param :cliente, desc: "Restringe a um cliente específico do acervo (ex.: \"Petrobras\")", required: false

  SOURCES = {
    "papyrus" => Rag::DocumentClassifier::VOICE_OF_PAPYRUS,
    "cliente" => %w[tr_cliente anexo_tecnico modelo_documento documento_contratual],
    "tudo" => nil
  }.freeze

  LIMIT = 5

  def initialize(retriever: nil)
    super()
    @retriever = retriever || Rag::Retriever.new
  end

  def execute(busca:, fonte: "papyrus", cliente: nil)
    return { error: "Preciso saber o que buscar no acervo." }.to_json if busca.to_s.strip.blank?

    hits = @retriever.call(
      busca.to_s.strip,
      roles: SOURCES.fetch(fonte.to_s.downcase, SOURCES["papyrus"]),
      limit: LIMIT,
      client_name: cliente.presence
    )

    return { resultados: [], aviso: "Nada parecido no acervo histórico." }.to_json if hits.empty?

    {
      resultados: hits.map { |hit| present(hit) },
      instrucao: "Cite a 'referencia' de cada trecho que você usar, no corpo da resposta ao consultor."
    }.to_json
  rescue StandardError => e
    Rails.logger.error("SearchHistoricalArchiveTool falhou: #{e.class} #{e.message}")
    { error: "Não consegui consultar o acervo agora." }.to_json
  end

  private

  # Além dos campos soltos, cada trecho vem com a citação já montada em `referencia`. Deixar a
  # IA compor a frase de origem a partir dos metadados dá margem a ela simplesmente não compor —
  # com o texto pronto, citar é mais fácil que omitir.
  def present(hit)
    chunk = hit.chunk
    proposal = chunk.historical_proposal

    {
      trecho: chunk.content,
      referencia: reference_for(proposal, hit),
      origem: {
        cliente: chunk.client_name,
        documento: proposal.filename,
        secao: hit.section.presence,
        tipo: chunk.role,
        ano: proposal.year
      }.compact,
      similaridade: hit.similarity
    }
  end

  def reference_for(proposal, hit)
    projeto = [ proposal.job_number, proposal.client_name ].compact_blank.join(" — ")
    detalhe = [ hit.section.presence, proposal.year ].compact_blank.join(", ")
    # "acervo" = documento histórico assinado; "proposta gerada" = saiu deste sistema e foi
    # aprovada aqui. A distinção precisa chegar ao consultor junto com o trecho.
    fonte = proposal.origin == "sistema" ? "proposta gerada no sistema" : "acervo Papyrus"

    "#{fonte}: projeto #{projeto}#{" (#{detalhe})" if detalhe.present?}"
  end
end
