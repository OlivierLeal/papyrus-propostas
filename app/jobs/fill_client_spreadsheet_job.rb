# Preenche uma planilha do cliente (PPU, DFP de formação de preço, qualquer outra) a partir da
# proposta — ou conclui que ela é só referência (`not_applicable`). Sempre em background (disparado
# por FillClientSpreadsheetTool, pelo botão da tela ou pela geração da proposta): a
# leitura da planilha pela IA é chamada síncrona e não pode rodar dentro de uma tool call (CLAUDE.md
# seção 8, reentrância de Conversation#complete).
#
# Divisão de trabalho (CLAUDE.md seção 1): a IA INTERPRETA a planilha — que é diferente a cada
# cliente — e devolve um plano citando chaves do catálogo de fatos; o Ruby resolve os valores,
# calcula preço unitário/rateio e escreve (Spreadsheets::PlanExecutor). Número nunca vem da IA.
class FillClientSpreadsheetJob < ApplicationJob
  queue_as :default

  def perform(spreadsheet_fill_id)
    fill = SpreadsheetFill.find_by(id: spreadsheet_fill_id)
    return unless fill&.processing?

    conversation = fill.conversation
    proposal = conversation.proposal
    pricing = proposal&.project_pricing
    return fail!(fill, "A proposta ainda não tem precificação.") unless pricing

    source_bytes = fill.source_blob.download
    catalog = Spreadsheets::FactCatalog.new(proposal)
    target = catalog["proposta.total"].value.round(2)

    plan = ask_plan(conversation, prompt(fill, Spreadsheets::Workbook.open(source_bytes), catalog))
    return fail!(fill, "A IA não devolveu um plano de preenchimento legível.") unless plan
    return not_applicable!(fill, plan) if plan["preencher"] == false && !fill.forced?

    plan = apply_mirrored_prices(plan, fill, catalog, pricing)

    result, sheet_total = execute(plan, source_bytes, catalog, fill)
    # Rodada de correção: o total que a PRÓPRIA planilha calcula não bateu com a proposta (ex.: a IA
    # pôs diárias numa coluna de horas). A IA recebe as abas com os valores calculados e refaz o plano.
    if sheet_total && (sheet_total - target).abs > TOTAL_TOLERANCE
      revised = ask_plan(conversation, correction_prompt(plan, result, sheet_total, target, catalog))
      revised &&= apply_mirrored_prices(revised, fill, catalog, pricing)
      plan, result, sheet_total = [ revised, *execute(revised, source_bytes, catalog, fill) ] if revised
    end

    fill.result.attach(io: StringIO.new(result.bytes), filename: fill.result_filename, content_type: fill.source_blob.content_type)
    totals = sheet_total ? { planilha: sheet_total.to_f, proposta: target.to_f } : result.totals
    warnings = result.warnings + Array(@mirrored_warnings)
    warnings += [ "Não consegui recalcular a planilha pra conferir o total — confira ao abrir." ] if sheet_total.nil? && plan["celula_total"].present?
    if sheet_total && (sheet_total - target).abs > TOTAL_TOLERANCE && result.missing_keys.any? { |key| key.start_with?("bdi.") }
      warnings += [ "O total da planilha não fecha com o da proposta porque faltam os percentuais de BDI da Papyrus — o custo em si confere." ]
    end
    fill.update!(status: "done", plan: plan, facts_digest: catalog.digest(result.used_keys), report: {
      entries: result.entries, warnings: warnings, issues: result.issues, doubts: result.doubts,
      totals: totals, used_keys: result.used_keys
    })
    register_doubts!(conversation, result.doubts, fill)
    post_card!(fill)
  rescue Spreadsheets::Workbook::Error => e
    fail!(fill, e.message)
  rescue StandardError => e
    Rails.logger.error("[FillClientSpreadsheetJob] #{spreadsheet_fill_id}: #{e.class} #{e.message}")
    fail!(fill, "Não consegui preencher a planilha agora.") if fill
  end

  # Diferença aceitável entre o total recalculado da planilha e o da proposta (arredondamento das
  # fórmulas do cliente).
  TOTAL_TOLERANCE = 1

  private

  # Plano de uma DFP passa de 3 mil tokens; sem maxTokens explícito o Bedrock pode cortar a resposta
  # no meio do JSON (achado ao vivo: 1 de 2 rodadas da DFP da conversa 65 falhou assim). Resposta
  # ilegível ganha UMA nova tentativa pedindo só o JSON, compacto.
  MAX_PLAN_TOKENS = 16_000

  # Itens da precificação que espelham ESTA planilha (PricingItem#mirrored?): o preço unitário de
  # cada um sai do custo do próprio item ÷ a quantidade do cliente — sem rateio decidido pela IA.
  # O que não é de nenhum item espelhado (gestão num item comum, custos externos) é rateado entre
  # eles na proporção do custo. Substitui os "precos_unitarios" que a IA tenha proposto.
  def apply_mirrored_prices(plan, fill, catalog, pricing)
    items = pricing.pricing_items.select { |item| item.mirrored? && item.client_sheet["blob_id"].to_i == fill.source_blob_id }
    return plan if items.empty?

    own = catalog.pieces.group_by { |piece| items.find { |item| item.id == catalog.item_of(piece.key) }&.id }
    common = own.delete(nil) || []
    weights = items.to_h { |item| [ item.id, Array(own[item.id]).sum(0.to_d) { |piece| piece.value * catalog.piece_multiplier(piece.key) } ] }
    total_weight = weights.values.sum

    prices = items.map do |item|
      share = total_weight.positive? ? weights[item.id] / total_weight : 1.to_d / items.size
      { "aba" => item.client_sheet["aba"], "celula" => item.client_sheet["celula_preco"],
        "descricao" => [ item.client_code, item.name ].compact_blank.join(" "), "quantidade" => item.client_quantity.to_s,
        "composicao" => Array(own[item.id]).map { |piece| { "peca" => piece.key, "fracao" => 1 } } +
          common.map { |piece| { "peca" => piece.key, "fracao" => share.round(6).to_s } } }
    end
    @mirrored_warnings = quantity_mismatches(items, fill)
    plan.merge("precos_unitarios" => prices, "tipo_planilha" => "preco")
  end

  # O consultor pode ter mudado a quantidade na Tela de Precificação: a planilha mede a DELE.
  def quantity_mismatches(items, fill)
    workbook = Spreadsheets::Workbook.open(fill.source_blob.download)
    items.filter_map do |item|
      sheet_quantity = workbook.value(item.client_sheet["aba"], item.client_sheet["celula_quantidade"])
      next if !sheet_quantity.is_a?(Numeric) || sheet_quantity.to_d == item.client_quantity.to_d

      "#{item.client_code || item.name}: a precificação usa #{item.client_quantity.to_d.to_s('F')} e a planilha do cliente diz #{sheet_quantity} — o preço unitário foi calculado com a da precificação."
    end
  rescue Spreadsheets::Workbook::Error
    []
  end

  def ask_plan(conversation, text)
    conversation.with_params(inferenceConfig: { maxTokens: MAX_PLAN_TOKENS })
    plan = ask_json(conversation, text)
    plan || ask_json(conversation, "Sua resposta anterior não veio como JSON válido (pode ter sido cortada). " \
      "Responda de novo SOMENTE o JSON do plano, completo e compacto, sem nenhum texto antes ou depois.")
  end

  def ask_json(conversation, text)
    conversation.ask_internally(text, hide_response: true)
    plan = AiJsonResponse.parse(conversation.messages.where(role: "assistant").order(:created_at).last&.content)
    plan.is_a?(Hash) ? plan : nil
  end

  # Executa o plano sobre uma cópia limpa da planilha e recalcula. [Result, total da planilha ou nil]
  def execute(plan, source_bytes, catalog, fill)
    @recalculated = nil
    result = Spreadsheets::PlanExecutor.new(Spreadsheets::Workbook.open(source_bytes), catalog, plan).call
    total_cell = plan["celula_total"]
    return [ result, nil ] unless total_cell.is_a?(Hash) && total_cell["aba"].present? && total_cell["celula"].present?

    @recalculated = Spreadsheets::Recalculator.call(result.bytes, File.extname(fill.source_filename))
    value = @recalculated&.value(total_cell["aba"], total_cell["celula"])
    [ result, value.is_a?(Numeric) ? value.to_d.round(2) : nil ]
  rescue Spreadsheets::Workbook::Error
    [ result, nil ]
  end

  def correction_prompt(plan, result, sheet_total, target, catalog)
    touched = (Array(plan["tabelas"]).map { |t| t["aba"] } + Array(plan["celulas"]).map { |c| c["aba"] } +
               [ plan.dig("celula_total", "aba") ]).compact.uniq
    <<~TEXT
      CONFERÊNCIA: preenchi a planilha com o seu plano e recalculei. O total que a planilha calcula
      (#{plan.dig('celula_total', 'aba')}!#{plan.dig('celula_total', 'celula')}) deu R$ #{format('%.2f', sheet_total)},
      mas o preço da proposta é R$ #{format('%.2f', target)} (custo direto R$ #{format('%.2f', catalog['proposta.custo_direto'].value)}).
      #{"Avisos do preenchimento: #{(result.warnings + result.issues).join(' | ')}" if (result.warnings + result.issues).any?}

      Abaixo, as abas que você preencheu com o valor que cada fórmula calculou ("=fórmula → valor").
      Ache onde o custo ficou diferente — unidade trocada (diária numa coluna de horas: use
      .horas_diarias com .salario_hora_diaria), custo que ficou de fora (profissional com HH E
      diárias precisa de duas linhas), custo contado duas vezes — e devolva o plano COMPLETO
      corrigido, no mesmo formato JSON de antes (com "celula_total"). Se a diferença vier de dado da
      Papyrus NÃO INFORMADO no catálogo (ex.: percentuais de BDI), o plano não está errado: mantenha
      e NÃO abra dúvida por isso — o sistema já avisa o consultor.

      #{@recalculated&.to_prompt_text(computed: @recalculated, only: touched)}
    TEXT
  end

  # Planilha de referência (quantitativos, coordenadas, a planilha de custo antiga da Papyrus): não
  # há o que devolver. No automático fica só no painel "Arquivos"; pedido pelo consultor, vira card.
  def not_applicable!(fill, plan)
    fill.update!(status: "not_applicable", plan: plan, report: { reason: plan["motivo"].to_s.strip.presence || "Não é um formulário para a Papyrus preencher." })
    fill.automatic? ? fill.conversation.broadcast_refresh : post_card!(fill)
  end

  def fail!(fill, message)
    fill.update!(status: "failed", error: message)
    post_card!(fill)
  end

  def post_card!(fill)
    fill.conversation.messages.create!(role: "assistant", content: { spreadsheet_fill_id: fill.id }.to_json)
    fill.conversation.broadcast_refresh
  end

  # Dúvida de interpretação da planilha que muda preço/quantitativo vira pendência (trava a geração,
  # mesmo mecanismo do resumo — ver ProjectIssue).
  def register_doubts!(conversation, doubts, fill)
    open_questions = conversation.project_issues.open.map { |issue| normalize(issue.question) }
    doubts.each do |doubt|
      next if open_questions.include?(normalize(doubt))

      issue = conversation.project_issues.create!(question: doubt, impact: "Preenchimento da planilha #{fill.source_filename}", source: "planilha")
      conversation.messages.create!(role: "assistant", content: { project_issue_id: issue.id }.to_json)
    end
  end

  def open_issues_text(conversation)
    open = conversation.project_issues.open.pluck(:question)
    return "" if open.empty?

    "Pendências JÁ ABERTAS nesta proposta (não repita, nem com outras palavras):\n" +
      open.map { |q| "        - #{q.truncate(200)}" }.join("\n")
  end

  def normalize(text) = I18n.transliterate(text.to_s.downcase).gsub(/[^a-z0-9]+/, " ").strip

  def prompt(fill, workbook, catalog)
    <<~TEXT
      TAREFA: a planilha "#{fill.source_filename}" foi anexada nesta proposta. Primeiro decida se ela é
      um FORMULÁRIO que a Papyrus deve devolver preenchido (lista de preços/PPU, formação de preço/DFP,
      BDI, encargos, quadro de equipe, dados cadastrais da empresa, checklist, declaração de
      quantidades…) ou só MATERIAL DE REFERÊNCIA (quantitativos, coordenadas, cronograma ou dados do
      próprio cliente, a planilha de custo interna da Papyrus, qualquer coisa que não tenha campo
      para o licitante). #{fill.forced? ? "O CONSULTOR CONFIRMOU que ela deve ser preenchida: trate como formulário e preencha o que o catálogo permitir." : "Na dúvida, se não há campo pedindo dado do licitante, é referência."}
      Se for referência, responda só {"preencher": false, "motivo": "uma frase dizendo o que ela é"}.

      Se for formulário: você NÃO escreve número nenhum — diz onde cada coisa vai, citando as CHAVES
      do catálogo de fatos abaixo, e o sistema calcula e escreve. O formulário pode não ter nada de
      preço (equipe, dados da empresa): preencha o que ele pede e marque "tipo_planilha": "formulario".
      Se ele forma o PREÇO da proposta, "tipo_planilha": "preco".
      #{"Orientação do consultor: #{fill.instructions}" if fill.instructions.present?}

      COMO LER A PLANILHA
      - Cada célula aparece como "ENDEREÇO: conteúdo"; "=..." é fórmula (nunca aponte célula com
        fórmula — ela calcula sozinha). Leia as instruções da própria planilha (abas de instrução,
        rótulos, cabeçalhos) antes de decidir.
      - Aba oculta que a planilha manda preencher (ex.: habilitada por um menu SIM/NÃO) entra em
        "abas_mostrar" — e o SIM/NÃO do menu vai em "celulas" com "texto".

      TIPOS DE PLANILHA
      1. Lista de preços do cliente (PPU, planilha de quantidades): o cliente dá os itens e as
         quantidades, o licitante preenche o PREÇO UNITÁRIO. Use "precos_unitarios": para cada
         célula de preço unitário, diga a quantidade (célula da quantidade na mesma linha, em
         "quantidade_celula") e a "composicao" — quais PEÇAS DE CUSTO do catálogo compõem aquele
         item e em que fração. Cada peça tem que ser distribuída por inteiro: a soma das frações de
         uma peça, em todos os itens, é 1 (ex.: coordenação 0,5 no item de gestão e 0,5 no de
         relatório). Toda peça de custo precisa entrar em algum item. O sistema aplica BDI e
         impostos e faz o total da planilha bater com o total da proposta.
      2. Formação de preço / composição de custos (DFP, BDI, encargos): o licitante abre salário,
         encargos, equipamentos, serviços, BDI. Use "tabelas" (uma linha por profissional ou por
         custo, a partir da linha-modelo da aba) e "celulas" (percentuais de BDI e tributos,
         dados da empresa). Salário e encargos: use as chaves .salario_hh/.encargos_pct/.hh (ou as
         de diária). Logística: as peças C…; custos de item: K…; externos: E….
      3. Qualquer outra: combine os dois, o que a planilha pedir.

      REGRAS
      - "fato": uma chave do catálogo (é o jeito de pôr qualquer número ou dado da proposta).
      - "texto": só rótulo curto que não existe no catálogo (Sim, Não, Horista, Mensalista, um nome
        de categoria) — nunca número nem valor.
      - Pergunta sobre a situação da Papyrus que o catálogo não responde (benefício fiscal,
        desoneração, isenção, cadastro): NÃO responda por conta própria — deixe a célula em branco e
        liste em "faltando" ("Benefício fiscal no estado (DADOS GERAIS!B34)"). "faltando" é só pra
        dado que NÃO existe no catálogo; chave "NÃO INFORMADO" o sistema já aponta sozinho.
      - "numero": só contagem pequena que você lê/deduz da própria planilha (nunca dinheiro).
      - Célula de rótulo terminada em ":" (ex.: "LICITANTE:") recebe o dado junto, não precisa
        achar célula vizinha.
      - Profissional com horas-homem E diárias: duas linhas na tabela (uma de HH, uma de diárias).
        Coluna de horas: .hh com .salario_hh; diárias em horas: .horas_diarias com
        .salario_hora_diaria. Nunca diária numa coluna de horas.
      - Não preencha célula só pra pôr zero: deixe em branco o que não se aplica.
      - "celula_total": a célula onde a planilha calcula o PREÇO TOTAL (ex.: total geral, valor
        total da proposta). O sistema recalcula e confere com o total da proposta.
      - Chave com valor "NÃO INFORMADO" pode ser citada: o sistema avisa o consultor que falta.
      - Quando a planilha pede algo que a proposta não tem, ou os quantitativos do cliente não
        batem com a proposta (ex.: diárias pedidas × diárias precificadas) de um jeito que muda o
        preço, escreva em "duvidas" uma pergunta direta e respondível ao consultor/cliente — cada
        dúvida TRAVA a geração da proposta até ser respondida. Nunca é dúvida: dado da Papyrus que
        falta (vai em "faltando"), explicação sobre o total, o que o sistema calcula, cadastro, nem
        o que já está nas pendências abertas abaixo.
      #{open_issues_text(fill.conversation)}

      Responda SOMENTE com JSON:
      {"preencher": true, "tipo_planilha": "preco",
       "abas_mostrar": ["aba"],
       "celulas": [{"aba": "…", "celula": "B26", "fato": "papyrus.cnpj"}, {"aba": "…", "celula": "C3", "texto": "SIM"}],
       "precos_unitarios": [{"aba": "…", "celula": "F7", "descricao": "…", "quantidade_celula": "E7",
                             "composicao": [{"peca": "L124", "fracao": 1}, {"peca": "C5.hospedagem", "fracao": 0.5}]}],
       "tabelas": [{"aba": "…", "linha_modelo": 3, "linhas": [{"A": {"fato": "L124.profissional"}, "C": {"fato": "L124.salario_hh"}, "D": {"texto": "Horista"}}]}],
       "celula_total": {"aba": "…", "celula": "E3"},
       "faltando": ["…"],
       "duvidas": ["…"]}

      CATÁLOGO DE FATOS DA PROPOSTA (chave = valor — rótulo; "[peça de custo]" = entra no rateio)
      #{catalog.to_prompt_text}

      PLANILHA
      #{workbook.to_prompt_text}
    TEXT
  end
end
