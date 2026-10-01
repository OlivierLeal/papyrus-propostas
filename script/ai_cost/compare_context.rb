# Compara a resposta da IA com o histórico COMPLETO (como o sistema manda hoje) contra versões
# ENXUTAS do mesmo histórico, pra decidir se dá pra cortar custo de entrada sem perder qualidade.
#
# Variantes:
#   completo      — exatamente o que RespondToMessageJob/ask_internally mandam hoje.
#   enxuto        — tira as trocas INTERNAS antigas (pedido de ask_internally + chamadas de
#                   ferramenta + resposta interna). Quando a troca deixou uma resposta VISÍVEL (ex.:
#                   o resumo do GenerateSummaryJob), ela fica, precedida de um marcador curto no
#                   lugar do pedido. Mensagens do consultor, respostas do chat e o snapshot ficam.
#   completo_repeticao — o mesmo histórico completo de novo: CONTROLE. Mede quanto a resposta
#                   varia sozinha (o modelo não é determinístico); diferença menor que essa não
#                   é perda causada pelo corte.
#   enxuto_curto  — enxuto + resultados de ferramenta longos de turnos ANTERIORES viram uma
#                   referência curta ("chame a ferramenta de novo se precisar").
#
# Cada pergunta roda nas 3 variantes com o mesmo modelo e as mesmas ferramentas (as que gravam
# algo ficam desligadas; as de busca rodam de verdade). Um juiz (mesmo modelo, sem histórico)
# compara cada variante enxuta com a completa. Tudo dentro de uma transação desfeita — nada fica
# gravado no banco.
#
# Uso:
#   bin/rails runner script/ai_cost/compare_context.rb --conversations 65,63,31
#   opções: --questions normas,decisoes  --variants completo,enxuto  --no-judge  --no-job
#
# Custo: cada chamada "completo" numa conversa grande passa de 200 mil tokens (~US$ 0,60 no
# Sonnet). O script imprime o custo estimado no fim.
require "optparse"
require "erb"

options = { conversations: [ 65 ], questions: nil, variants: %w[completo enxuto enxuto_curto], judge: true, job: true }
OptionParser.new do |o|
  o.on("--conversations LIST") { |v| options[:conversations] = v.split(",").map(&:to_i) }
  o.on("--questions LIST") { |v| options[:questions] = v.split(",") }
  o.on("--variants LIST") { |v| options[:variants] = v.split(",") }
  o.on("--no-judge") { options[:judge] = false }
  o.on("--no-job") { options[:job] = false }
end.parse!(ARGV)

module CompareContext
  QUESTIONS = {
    "normas" => "Quais exigências legais (normas, com número e artigo quando houver) se aplicam a este projeto e o que cada uma implica no escopo da proposta? Responda com o que você já tem; não precisa pesquisar de novo se já tiver a informação.",
    "complementares" => "O que cada documento enviado (ET, TR e complementares) trouxe de relevante para escopo, equipe, prazo ou preço? Cite o documento de cada informação.",
    "decisoes" => "Quais decisões eu já tomei nesta conversa (e na tela) e o que ainda está pendente antes de enviar a proposta ao cliente?",
    "equipe" => "Quais profissionais você recomenda para este projeto, com a função de cada um e o motivo, considerando o escopo e as exigências dos documentos?"
  }.freeze

  # Ferramentas com efeito colateral (gravam proposta, card, achado...). Ficam registradas (a
  # definição pesa no prompt igual em produção), mas a execução vira um aviso.
  SIDE_EFFECT_TOOLS = %w[
    GenerateProposalDocumentTool AddExternalCostTool SetProjectLocationTool InsertScheduleSectionTool
    FillClientSpreadsheetTool RememberForFutureProposalsTool RegisterPendingIssueTool
    AnswerPendingIssueTool LearnFromRevisedProposalTool
  ].freeze

  TOOL_RESULT_KEEP = 1500
  # Sonnet 4.6 no Bedrock (US$ por milhão de tokens) — só pra estimativa do custo do teste.
  PRICE = { input: 3.0, output: 15.0, cache_read: 0.30, cache_write: 3.75 }.freeze

  module_function

  def snapshot?(message)
    message.role.to_s == "user" && message.content.to_s.start_with?(Conversation::PROPOSAL_STATE_MARKER)
  end

  def tool_call_ids
    @tool_call_ids ||= {}
  end

  def has_tool_calls?(message)
    message.role.to_s == "assistant" && message.tool_calls.exists?
  end

  # Segmento = de uma mensagem de usuário até a próxima. Snapshot não abre segmento (pertence ao
  # turno do consultor). Segmento é interno quando abre com um pedido interno (ask_internally).
  def segments(ordered)
    ordered.each_with_object([]) do |message, list|
      opens = message.role.to_s == "user" && !snapshot?(message)
      list << { internal: opens && message.internal, messages: [] } if opens || list.empty?
      list.last[:messages] << message
    end
  end

  def trimmed(ordered)
    segments(ordered).flat_map do |segment|
      next segment[:messages].map(&:to_llm) unless segment[:internal]

      opener = segment[:messages].first
      kept = segment[:messages].drop(1).select do |m|
        snapshot?(m) || (m.role.to_s == "assistant" && !m.internal && m.content.present? && !has_tool_calls?(m))
      end
      visible = kept.reject { |m| snapshot?(m) }
      out = []
      if visible.any?
        title = opener.content.to_s.lines.first.to_s.strip.truncate(160)
        out << RubyLLM::Message.new(role: :user, content: "[Tarefa interna do sistema, pedido omitido do histórico: #{title}]")
      end
      out + kept.map(&:to_llm)
    end
  end

  # Resultados de ferramenta longos ficam inteiros só no ÚLTIMO turno do consultor.
  def shortened(ordered)
    last_turn = segments(ordered).reject { |s| s[:internal] }.last
    keep_ids = last_turn ? last_turn[:messages].map(&:id).to_set : Set.new
    trimmed_llm = trimmed(ordered)
    by_call = ordered.select { |m| m.role.to_s == "tool" }.index_by { |m| m.to_llm.tool_call_id }

    trimmed_llm.map do |llm|
      next llm unless llm.role == :tool

      original = by_call[llm.tool_call_id]
      text = llm.content.is_a?(RubyLLM::Content) ? llm.content.text.to_s : llm.content.to_s
      next llm if text.size <= TOOL_RESULT_KEEP || (original && keep_ids.include?(original.id))

      short = "[Resultado de ferramenta omitido do histórico (#{text.size} caracteres) para economizar contexto. " \
              "Se precisar do conteúdo, chame a ferramenta de novo.] Início: #{text[0, 300]}"
      RubyLLM::Message.new(role: :tool, content: short, tool_call_id: llm.tool_call_id)
    end
  end

  def history(conversation, variant)
    ordered = conversation.send(:order_messages_for_llm, conversation.messages.reload.to_a)
    case variant
    when "completo", "completo_repeticao" then ordered.map(&:to_llm)
    when "enxuto" then trimmed(ordered)
    when "enxuto_curto" then shortened(ordered)
    else raise ArgumentError, variant
    end
  end

  def tools_for(conversation)
    tools = []
    tools << GenerateProposalDocumentTool.new(conversation: conversation)
    tools << AddExternalCostTool.new(proposal: conversation.proposal) if conversation.proposal
    tools << SetProjectLocationTool.new(conversation: conversation)
    tools << InsertScheduleSectionTool.new(proposal: conversation.proposal) if conversation.proposal
    tools << FillClientSpreadsheetTool.new(conversation: conversation) if conversation.proposal
    tools << SearchHistoricalArchiveTool.new if HistoricalProposalChunk.embedded.exists?
    tools << SearchProjectPrecedentsTool.new(conversation: conversation) if JobPrecedent.searchable.exists?
    tools << SearchLegalNormsTool.new if Cal::Client.configured?
    tools << SearchLegalNormsArchiveTool.new if LegalNormChunk.embedded.exists?
    tools << WebSearchTool.new if WebSearch::Client.configured?
    tools << RememberForFutureProposalsTool.new(conversation: conversation)
    tools << RegisterPendingIssueTool.new(conversation: conversation)
    tools << AnswerPendingIssueTool.new(conversation: conversation) if conversation.project_issues.open.exists?
    tools << LearnFromRevisedProposalTool.new(conversation: conversation)
    tools.each do |tool|
      next unless SIDE_EFFECT_TOOLS.include?(tool.class.name)

      tool.define_singleton_method(:execute) { |**_args| { aviso: "Ferramenta desativada neste teste. Responda só com o que já sabe." } }
    end
  end

  def job_tools
    tools = []
    tools << SearchHistoricalArchiveTool.new if HistoricalProposalChunk.embedded.exists?
    tools << SearchLegalNormsTool.new if Cal::Client.configured?
    tools
  end

  def ask(conversation, variant, prompt, tools:)
    model = conversation.model
    chat = RubyLLM.chat(model: model.model_id, provider: model.provider.to_sym)
    history(conversation, variant).each { |m| chat.add_message(m) }
    tools.each { |t| chat.with_tool(t) }
    usage = { calls: 0, input: 0, output: 0, cache_read: 0, cache_write: 0, tool_calls: [] }
    chat.on_tool_call { |call| usage[:tool_calls] << call.name }
    chat.on_end_message do |msg|
      next unless msg&.role == :assistant

      usage[:calls] += 1
      usage[:input] += msg.input_tokens.to_i
      usage[:output] += msg.output_tokens.to_i
      usage[:cache_read] += msg.cached_tokens.to_i
      usage[:cache_write] += msg.cache_creation_tokens.to_i
    end
    started = Time.current
    response = chat.ask(prompt)
    usage.merge(answer: response.content.to_s, seconds: (Time.current - started).round(1), history_messages: chat.messages.size)
  rescue StandardError => e
    (usage || {}).merge(answer: "ERRO: #{e.class}: #{e.message}", error: true)
  end

  def cost(usage)
    (usage[:input].to_i * PRICE[:input] + usage[:output].to_i * PRICE[:output] +
      usage[:cache_read].to_i * PRICE[:cache_read] + usage[:cache_write].to_i * PRICE[:cache_write]) / 1_000_000.0
  end

  JUDGE_PROMPT = <<~PROMPT.freeze
    Você avalia se cortar parte do histórico de uma conversa piorou a resposta de um assistente de
    propostas de consultoria ambiental. A resposta A foi dada com o histórico COMPLETO e serve de
    referência; a resposta B foi dada com um histórico ENXUTO (sem as trocas internas antigas do
    sistema). Compare só o CONTEÚDO (fatos, números, normas, documentos, decisões, pessoas), não o
    estilo nem o tamanho. Responda só com JSON:
    {"veredito": "equivalente" | "B_pior" | "B_melhor",
     "faltam_em_B": ["fato relevante que está em A e não em B"],
     "faltam_em_A": ["fato relevante que está em B e não em A"],
     "contradicoes": ["onde A e B afirmam coisas diferentes"],
     "observacao": "uma frase"}
    Diferenças de estilo, ordem ou detalhe irrelevante contam como "equivalente".

    PERGUNTA:
    %<question>s

    RESPOSTA A (histórico completo):
    %<a>s

    RESPOSTA B (histórico enxuto):
    %<b>s
  PROMPT

  def judge(conversation, question, a, b)
    chat = RubyLLM.chat(model: conversation.model.model_id, provider: conversation.model.provider.to_sym)
    response = chat.ask(format(JUDGE_PROMPT, question: question, a: a, b: b))
    usage = { input: response.input_tokens.to_i, output: response.output_tokens.to_i }
    (AiJsonResponse.parse(response.content) || { "veredito" => "ilegível", "observacao" => response.content.to_s.truncate(300) }).merge("_usage" => usage)
  rescue StandardError => e
    { "veredito" => "erro", "observacao" => "#{e.class}: #{e.message}", "_usage" => {} }
  end
end

out_dir = Rails.root.join("tmp/ai_cost", Time.current.strftime("%Y%m%d-%H%M%S"))
FileUtils.mkdir_p(out_dir)
results = []
total_cost = 0.0

options[:conversations].each do |conversation_id|
  ActiveRecord::Base.transaction do
    conversation = Conversation.find(conversation_id)
    conversation.refresh_proposal_state_snapshot!
    puts "\n== Conversa #{conversation_id} — #{conversation.client_name} (#{conversation.messages.count} mensagens)"

    cases = CompareContext::QUESTIONS.slice(*(options[:questions] || CompareContext::QUESTIONS.keys)).map do |key, q|
      { key: key, prompt: q, label: q, tools: -> { CompareContext.tools_for(conversation) } }
    end
    if options[:job] && conversation.proposal
      prompt = conversation.proposal.send(:team_suggestion_prompt)
      cases << { key: "job_equipe", prompt: prompt, label: "Replay do SuggestTeamJob (prompt real de sugestão de equipe, resposta em JSON)",
                 tools: -> { CompareContext.job_tools } }
    end

    cases.each do |c|
      runs = options[:variants].index_with do |variant|
        print "  #{c[:key]} / #{variant}… "
        usage = CompareContext.ask(conversation, variant, c[:prompt], tools: c[:tools].call)
        total_cost += CompareContext.cost(usage)
        puts "#{usage[:input]} in, #{usage[:output]} out, #{usage[:calls]} chamadas, US$ #{CompareContext.cost(usage).round(2)}#{' ERRO' if usage[:error]}"
        usage
      end
      judgments = {}
      if options[:judge] && runs["completo"] && !runs["completo"][:error]
        (options[:variants] - [ "completo" ]).each do |variant|
          next if runs[variant][:error]

          judgments[variant] = CompareContext.judge(conversation, c[:label], runs["completo"][:answer], runs[variant][:answer])
          u = judgments[variant]["_usage"]
          total_cost += (u[:input].to_i * 3.0 + u[:output].to_i * 15.0) / 1_000_000.0
          puts "    juiz #{variant}: #{judgments[variant]['veredito']} — #{judgments[variant]['observacao']}"
        end
      end
      results << { conversation_id: conversation_id, client: conversation.client_name, case: c[:key], question: c[:label], runs: runs, judgments: judgments }
      File.write(out_dir.join("results.json"), JSON.pretty_generate(results))
    end
    raise ActiveRecord::Rollback
  end
end

# Relatório HTML local (tem dado de cliente — não publicar).
h = ->(s) { ERB::Util.html_escape(s.to_s) }
rows = results.map do |r|
  tokens = r[:runs].map do |variant, u|
    "<td>#{h[variant]}</td><td class=n>#{u[:input].to_i.to_fs(:delimited)}</td><td class=n>#{u[:cache_read].to_i.to_fs(:delimited)}</td>" \
      "<td class=n>#{u[:calls]}</td><td>#{h[Array(u[:tool_calls]).tally.map { |k, v| "#{k}×#{v}" }.join(', ')]}</td>" \
      "<td class=n>US$ #{CompareContext.cost(u).round(2)}</td><td>#{h[r[:judgments].dig(variant, 'veredito') || '—']}</td>"
  end
  answers = r[:runs].map { |variant, u| "<div class=col><h4>#{h[variant]}</h4><pre>#{h[u[:answer]]}</pre></div>" }.join
  verdicts = r[:judgments].map do |variant, j|
    items = %w[faltam_em_B faltam_em_A contradicoes].map { |k| "<b>#{k}</b><ul>#{Array(j[k]).map { |i| "<li>#{h[i]}</li>" }.join}</ul>" }.join
    "<div class=judge><h4>Juiz: #{h[variant]} → #{h[j['veredito']]}</h4><p>#{h[j['observacao']]}</p>#{items}</div>"
  end.join
  <<~HTML
    <section><h2>Conversa #{r[:conversation_id]} · #{h[r[:client]]} · #{h[r[:case]]}</h2>
    <p class=q>#{h[r[:question].truncate(400)]}</p>
    <table><tr><th>variante</th><th>tokens entrada</th><th>cache lido</th><th>chamadas</th><th>ferramentas</th><th>custo</th><th>juiz</th></tr>
    #{tokens.map { |t| "<tr>#{t}</tr>" }.join}</table>#{verdicts}
    <details><summary>Respostas lado a lado</summary><div class=cols>#{answers}</div></details></section>
  HTML
end
File.write(out_dir.join("report.html"), <<~HTML)
  <!doctype html><meta charset=utf-8><title>Comparação de contexto</title>
  <style>body{font:14px system-ui;margin:24px;max-width:1500px}table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #ccc;padding:4px 8px}
  .n{text-align:right}.cols{display:flex;gap:12px}.col{flex:1;min-width:0}pre{white-space:pre-wrap;background:#f6f6f6;padding:8px;font-size:12px}
  .judge{background:#fffbe6;padding:6px 10px;margin:6px 0}.q{color:#555}section{border-top:2px solid #333;margin-top:24px}</style>
  <h1>Histórico completo × enxuto</h1><p>Custo total do teste: US$ #{total_cost.round(2)}</p>
  #{rows.join}
HTML

puts "\nCusto estimado do teste: US$ #{total_cost.round(2)}"
puts "Relatório: #{out_dir.join('report.html')}"
