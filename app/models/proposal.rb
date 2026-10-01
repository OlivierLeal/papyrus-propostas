class Proposal < ApplicationRecord
  belongs_to :conversation
  belongs_to :reopened_by, class_name: "User", optional: true
  has_one :project_pricing, dependent: :destroy
  has_many_attached :generated_documents

  STATUSES = %w[draft priced approved].freeze
  DOCUMENT_SPLITS = %w[combined separated].freeze

  validates :status, inclusion: { in: STATUSES }
  validates :document_split, inclusion: { in: DOCUMENT_SPLITS }

  # PTC = técnica e comercial num arquivo só; PT = só a técnica; PC = só a comercial (ver
  # GenerateProposalDocumentTool#execute — cada arquivo gerado usa o prefixo do que ele é).
  DOCX_NUMERO_PREFIXES = { "combined" => "PTC", "tecnica" => "PT", "comercial" => "PC" }.freeze

  # Número da proposta = prefixo do tipo de arquivo + ano de criação (2 dígitos) + id da tabela,
  # preenchido com zero à esquerda até 3 dígitos (ver passo a passo interno, item 1 — exemplo real
  # deles: PTC21089) — automático, não é a IA que decide nem precisa de confirmação com a Charlene
  # antes de gerar o rascunho. Mesmo id em toda revisão/variante da mesma proposta — só o prefixo
  # muda entre técnica/comercial/combinado.
  def docx_numero_proposta(kind = "combined")
    "#{DOCX_NUMERO_PREFIXES.fetch(kind, "PTC")}#{created_at.strftime("%y")}#{id.to_s.rjust(3, "0")}"
  end

  # Igual a #docx_numero_proposta, mas sem o prefixo de letras (PT/PTC/PC) — só pra capa do
  # `.docx` (2026-09, pedido do consultor: "ao invés de PT/PTC, só o número"). O modelo já
  # concatena "/20" + "26" + " - Rev. {{REVISAO_ATUAL}}" depois do placeholder na própria capa
  # (string fixa do modelo, não campo calculado), então só o prefixo de letras precisa sair
  # daqui — em qualquer outro lugar (nome de arquivo, busca de conversa, indexação no RAG)
  # continua sendo #docx_numero_proposta, com prefixo, sem mudança nenhuma.
  def docx_numero_capa(kind = "combined")
    docx_numero_proposta(kind).sub(/\A[A-Z]+/, "")
  end

  # Nome de arquivo no padrão pedido pelo consultor (2026-09): número / cliente / ato de
  # licenciamento (LP, LI, RLP, LO, ASV, AMF etc.) / nome do projeto / revisão. Município/UF
  # SAÍRAM do nome de propósito — não fazem parte deste padrão. "Ato" e "nome do projeto" vêm dos
  # achados `tipo_licenca`/`empreendimento` já extraídos do ET/TR (ver ProjectFinding) — não são
  # parâmetro novo nenhum, só passaram a alimentar o nome do arquivo também.
  # "Rev.00", "Rev 1", "rev.02" — qualquer forma de revisão que o consultor tenha escrito à mão
  # no nome que ele ditou. Se ele escreveu uma, é a dele que vale.
  REVISION_MARKER = /rev\.?\s*\d+/i

  # Prefixo do número da proposta no começo do nome (PTC26002_...), que é o que distingue
  # técnica de comercial na convenção da Papyrus.
  NUMBER_PREFIX = /\A(PTC|PT|PC)\d/i

  def docx_filename(kind)
    base = docx_filename_override.presence ? custom_filename_base(kind) : standard_filename_base(kind)
    base += "_Rev.#{format("%02d", version - 1)}" unless base.match?(REVISION_MARKER)

    "#{base}.docx"
  end

  # Nome do arquivo MSPDI (cronograma pro MS Project, ver ScheduleMspdiExporter/CLAUDE.md seção
  # 8) — mesma base do nome da proposta TÉCNICA (o cronograma nunca é dado de preço, sai igual em
  # qualquer status), só com sufixo do tipo e extensão .xml em vez de .docx.
  # Unidades de esforço que a IA usa ao sugerir equipe (2026-09: hora escritório/hora campo
  # viraram hora-homem e diária). Mesmo texto nos dois prompts de equipe.
  EFFORT_UNITS_GUIDE = <<~TEXT.strip
    - "man_hours" = HORAS-HOMEM (HH) de trabalho técnico/escritório: elaboração, análise,
      geoprocessamento, relatórios, reuniões, coordenação.
    - "field_days" = DIÁRIAS de campo: quantos dias o profissional fica em campo (vistoria,
      campanha de fauna/flora, levantamento). É contagem de DIAS, nunca de horas.
  TEXT

  SCHEDULE_FILENAME_LABELS = { "servico" => "Cronograma_Servico", "implantacao" => "Cronograma_Implantacao" }.freeze

  def schedule_filename(type)
    base = docx_filename("tecnica").sub(/\.docx\z/, "")
    "#{base}_#{SCHEDULE_FILENAME_LABELS.fetch(type)}.xml"
  end

  # Siglas dos atos de licenciamento (LP, LI, RLP, ASV…) dos achados `tipo_licenca` ativos desta
  # conversa. Usado pelo gerador do .docx pra aplicar a regra de prazo de 12 meses da família
  # Prévia/Instalação (ver GenerateProposalDocumentTool) e, internamente, por #ato_licenciamento.
  def license_act_acronyms
    # Norma antes do pedido do cliente (Conversation#framing_values) — antes misturava as siglas das
    # duas fontes ("LP" do ET + "LP+LI" do CAL).
    conversation.framing_values("tipo_licenca")
      .flat_map { |texto| license_acronyms_in(texto) }.uniq
  end

  # Linhas do Quadro "Membros da equipe" (seção EQUIPE TÉCNICA) do .docx: uma por
  # proposal_professional, no formato [SETOR, FUNÇÃO, PROFISSIONAL, HABILITAÇÃO/REGISTRO].
  # A tabela do modelo virou dinâmica (2026-09) — antes era um esqueleto quase fixo com só 2
  # vagas de placeholder (líder + segurança do trabalho). O SETOR é derivado: Diretoria =
  # always_included com "diretor" no cargo; Gestão = os demais always_included (Coordenação);
  # Execução = todo o resto. Ordena por setor e depois por nome. FUNÇÃO é o entregável dele
  # NESTA proposta (deliverable_name), não o cargo genérico.
  DOCX_TEAM_SECTORS = { diretoria: 0, gestao: 1, execucao: 2 }.freeze

  def self.normalize_person_name(name) = I18n.transliterate(name.to_s.downcase).squish

  # functions: { nome normalizado => macrogrupo } que a IA passa na geração (funcoes_equipe).
  # Apoio (professionals.technical_team = false) não entra no quadro — Charlene, 2026-10-01.
  def team_rows_for_docx(functions: {})
    lines = project_pricing&.proposal_professionals&.includes(:professional)&.to_a || []
    lines = lines.select { |line| line.professional.technical_team || line.professional.always_included }

    # UMA linha por profissional (2026-09-29): com a precificação por item, a mesma pessoa tem uma
    # linha de equipe em cada item (campo, elaboração, protocolo…) e saía repetida no quadro.
    lines.group_by(&:professional)
      .sort_by { |professional, _| [ DOCX_TEAM_SECTORS.fetch(docx_team_sector(professional)), professional.name.to_s ] }
      .map do |professional, professional_lines|
        habilitacao = [ professional.specialties.presence, professional.registration.presence ].compact.join(" — ")
        function = (functions[self.class.normalize_person_name(professional.name)] unless professional.always_included)
        [ docx_team_sector_label(professional), function || docx_team_function(professional, professional_lines), professional.name.to_s, habilitacao ]
      end
  end

  # Equipe fixa (Diretoria/Coordenação) aparece com o CARGO, não com o entregável que a IA escreveu
  # pra ela nesta proposta ("Coordenação de Negócios e Relacionamento com o Cliente") — 2026-09-29,
  # Charlene: "as funções aqui estão erradas". O resto, com o entregável PRINCIPAL desta proposta (o
  # de maior esforço, diária = 8 HH) — juntar todos deixava a coluna estreita com 10+ linhas.
  def docx_team_function(professional, lines)
    return professional.role.to_s if professional.always_included

    lines.max_by { |line| [ line.man_hours.to_f + line.field_days.to_f * 8, -line.id.to_i ] }.deliverable_name.to_s
  end

  # Reserva a próxima revisão direto no banco e devolve o número (2026-09-28, conversas 43/57: o
  # mesmo "Rev.01" saiu 2-3 vezes). increment! soma no banco mas usa o valor em MEMÓRIA pra montar
  # o nome — um job de fundo com a proposta carregada antes de uma geração pelo chat repetia a
  # revisão. UPDATE ... RETURNING é atômico: duas gerações simultâneas nunca pegam o mesmo número.
  def claim_next_version!
    next_version = self.class.connection.select_value(
      "UPDATE proposals SET version = version + 1, updated_at = NOW() WHERE id = #{id.to_i} RETURNING version"
    ).to_i
    self.version = next_version
    clear_attribute_change(:version)
    next_version
  end

  # Preço total por extenso na frase de abertura da seção 10 — o modelo da Papyrus (revisão de
  # 2026-08) deixou de trazer o quadro de preço aberto por profissional/entregável, então o valor
  # que o cliente lê é este. Continua vindo do motor determinístico, nunca da IA. Ficou sem uso
  # no corpo do texto desde 2026-09 (o quadro de Preço voltou, ver #docx_price_rows), mas o
  # placeholder {{PRECO_TOTAL}} continua mapeado em build_placeholders — inofensivo mesmo sem
  # aparecer mais no modelo, mesmo padrão de outros placeholders que saíram do texto (ver seção 8
  # do CLAUDE.md, "Ref.:" line).
  def docx_total_price
    "R$ #{format_currency(project_pricing.total_value)}"
  end

  # Linhas do Quadro de Preço (N° | SERVIÇO | PREÇO R$, reintroduzido em 2026-09), já com o N°.
  # Conforme ProjectPricing#price_presentation (2026-09-28, planilha real da Papyrus):
  # - "total": 1 linha, o preço total. `descricao_fallback` é o texto livre que a IA já escreve
  #   (descricao_servico) — só entra quando não dá pra derivar o nome do ato de licenciamento.
  # - "itens": uma linha por item (ProjectPricing#price_rows, calculado em Ruby) + TOTAL.
  # - "empreendimentos": as linhas por item + "Total – <empreendimento>" de cada um (rateio dos
  #   itens comuns, ProjectPricing#enterprise_totals) + TOTAL.
  # Linhas de total saem sem número (e em negrito, ProposalDocxFiller#fill_table!).
  def docx_price_rows(descricao_fallback: nil)
    total = format_currency(project_pricing.total_value)
    return [ [ "1", docx_servico_label(fallback: descricao_fallback), total ] ] if price_presentation_mode == "total"
    return detailed_price_rows + [ [ "", "TOTAL", total ] ] if price_presentation_mode == "detalhado"

    rows = project_pricing.price_rows.each_with_index.map { |(label, value), index| [ (index + 1).to_s, label, format_currency(value) ] }
    if price_presentation_mode == "empreendimentos"
      rows += project_pricing.enterprise_totals.map { |name, value| [ "", "TOTAL – #{name}", format_currency(value) ] }
    end
    rows + [ [ "", "TOTAL", total ] ]
  end

  # Forma do Quadro de Preço que de fato sai: cai pra "total" com um item só, e pra "itens" sem 2+
  # empreendimentos — nunca um quadro aberto de uma linha só.
  def price_presentation_mode
    mode = project_pricing.price_presentation
    return mode if mode == "detalhado"
    return "total" if mode == "total" || project_pricing.pricing_items.size < 2
    return "itens" if mode == "empreendimentos" && project_pricing.pricing_enterprises.size < 2

    mode
  end

  CAMPAIGN_COST_LABELS = {
    vehicle: "veículos", fuel: "combustível", meals: "alimentação", lodging: "hospedagem",
    extras: "pedágios, lavagens, deslocamentos locais, mateiro e EPI"
  }.freeze

  # Quadro de Preço DETALHADO (2026-09-30, pedido do cliente: "tem cliente que quer saber valor de
  # HH, logística detalhada, BDI, impostos, tudo separado"). Linhas de custo PURO (quantidade ×
  # valor unitário), depois o subtotal do custo direto, BDI, impostos e externos — a mesma
  # composição da Tela de Precificação (ProjectPricing#price_composition), que fecha centavo a
  # centavo com o total. A última linha de custo absorve o arredondamento das linhas, pro subtotal
  # bater com a soma. Linha sem número = subtítulo/subtotal, sai em negrito.
  # Serviço terceirizado nunca aparece como tal (regra da proposta): entra como "Serviços
  # especializados", sem descrição.
  def detailed_price_rows
    pricing = project_pricing
    composition = pricing.price_composition
    items = pricing.pricing_items.includes(:field_campaigns, proposal_professionals: :professional).to_a
    rows = []
    cost_rows = []

    items.each do |item|
      rows << [ "", item.name.upcase, "" ] if items.size > 1
      factor = item.days_factor
      item.proposal_professionals.sort_by { |line| [ line.professional.always_included ? 0 : 1, line.id ] }.each do |line|
        pro = line.professional
        who = [ pro.name, line.deliverable_name.presence ].compact.join(" – ")
        if line.man_hours.positive?
          cost_rows << (rows << [ nil, "Horas-homem: #{who} (#{number_br(line.man_hours)} HH × R$ #{format_currency(pro.rate_man_hour)})", line.man_hours * pro.rate_man_hour ]).last
        end
        days = line.field_days + line.commute_extra_days(factor)
        if days.positive?
          cost_rows << (rows << [ nil, "Diárias de campo: #{who} (#{number_br(days)} × R$ #{format_currency(pro.rate_daily)})", days * pro.rate_daily ]).last
        end
      end
      item.field_campaigns.each do |campaign|
        campaign.breakdown(pricing).each do |key, value|
          next unless value.positive?

          cost_rows << (rows << [ nil, "Logística – #{campaign.description}: #{CAMPAIGN_COST_LABELS.fetch(key)}", value ]).last
        end
      end
      item.costs.each do |cost|
        value = cost["quantity"].to_d * cost["unit_value"].to_d
        next unless value.positive?

        cost_rows << (rows << [ nil, "#{cost['description']} (#{number_br(cost['quantity'])} × R$ #{format_currency(cost['unit_value'])})", value ]).last
      end
    end

    cost_rows.each { |row| row[2] = row[2].to_d.round(2) }
    cost_rows.last[2] += composition[:direct] - cost_rows.sum { |row| row[2] } if cost_rows.any?

    rows << [ "", "SUBTOTAL – CUSTO DIRETO", composition[:direct] ]
    rows << [ nil, "BDI (× #{format_currency(pricing.bdi)})", composition[:bdi] ]
    rows << [ nil, "Impostos e despesas administrativas (× #{format_currency(pricing.tax_multiplier)})", composition[:taxes] ]
    pricing.other_external_costs.each { |cost, _| rows << [ nil, cost["description"].to_s, cost["value"].to_d ] }
    rows << [ nil, "Serviços especializados", composition[:outsourced] ] if composition[:outsourced].positive?

    number = 0
    rows.map do |label_number, label, value|
      shown = value == "" ? "" : format_currency(value)
      [ label_number.nil? ? (number += 1).to_s : label_number, label, shown ]
    end
  end

  # Nome do serviço pro Quadro de Preço — deriva do(s) ato(s) de licenciamento já identificados
  # (mesma sigla usada no nome do arquivo, #ato_licenciamento/#license_act_acronyms), nunca da
  # IA: é um fato do sistema, não texto livre (ex.: "RLP" → "Renovação da Licença Prévia - RLP").
  # Sem ato identificado (tipo de estudo sem achado de licença, ou sigla fora do catálogo de
  # LICENSE_ACT_NAMES), cai pro texto que a IA escreveu em descricao_servico — mesmo padrão de
  # "achado > texto livre" de #nome_projeto.
  def docx_servico_label(fallback: nil)
    siglas = license_act_acronyms
    nomes = siglas.filter_map { |sigla| LICENSE_ACT_NAMES.key(sigla) }.map { |nome| humanize_license_act_name(nome) }
    return "#{nomes.join(' e ')} - #{siglas.join('+')}" if nomes.present?

    fallback.to_s.strip.presence || "Serviço"
  end

  # Linhas do Quadro de Desembolso — [MARCO, %, VALOR R$]. O valor é calculado pelo sistema
  # (ProjectPricing#payment_schedule_amounts, % do total), nunca pela IA. 2026-09-27: voltou a
  # coluna de valor (pedido do consultor, "o desembolso tem que ser calculado"); a data de cada
  # parcela continua só na Tela de Precificação.
  def docx_payment_schedule_rows
    project_pricing.payment_schedule_amounts.map do |item|
      [ item["label"], "#{format_percentage(item['percentage'])}%", format_currency(item["amount"]) ]
    end
  end

  # Linhas da tabela "Sumário de Revisões" (página 2 do modelo) — cada geração vira uma linha
  # nova, nunca apaga histórico. As versões passadas vêm do metadata já gravado nos blobs de
  # generated_documents (version/description); a data de cada uma é a do próprio blob
  # (created_at), sem precisar de coluna própria. Chamado com `version` já incrementado pra
  # versão atual (ver GenerateProposalDocumentTool) — a linha dela entra por último.
  def docx_revision_rows(current_description:)
    # Blobs sem version no metadata são de antes desse controle existir — sem número de revisão
    # nem descrição pra mostrar, não entram na tabela (evita linha "-1" em branco no documento).
    # Filtra por v.to_i < version para nunca duplicar a revisão atual.
    past_rows = generated_documents.map(&:blob)
      .select { |blob| blob.metadata["version"].present? && blob.metadata["version"].to_i < version }
      .group_by { |blob| blob.metadata["version"] }
      .map do |v, blobs|
        blob = blobs.first
        rev_num = format("%02d", v.to_i - 1)
        desc = blob.metadata["description"].to_s.strip
        if v.to_i > 1 && (desc.blank? || desc.downcase.in?([ "emissão inicial", "emissao inicial" ]))
          desc = "Revisão solicitada pelo consultor"
        end
        [ rev_num, desc, blob.created_at.strftime("%d/%m/%Y") ]
      end
      .sort_by { |row| row[0] }

    curr_rev_num = format("%02d", version - 1)
    curr_desc = if version <= 1
      "Emissão Inicial"
    else
      desc = current_description.to_s.strip
      if desc.blank? || desc.downcase.in?([ "emissão inicial", "emissao inicial" ])
        "Revisão solicitada pelo consultor"
      else
        desc
      end
    end

    past_rows << [ curr_rev_num, curr_desc, Date.current.strftime("%d/%m/%Y") ]
  end

  def approve!
    transaction do
      update!(status: "approved", approved_at: Time.current, approved_total: project_pricing.total_value)
      conversation.update!(status: "completed")
    end
  end

  # Reabre uma precificação aprovada pra ajuste (2026-09-27, pedido do consultor: o cliente pede
  # mudança depois do preço aprovado). Volta a "priced" (editável) e a conversa volta a
  # "pricing"; o preço aprovado anterior fica em approved_total/approved_at pra referência.
  #
  # Preço aprovado fica congelado (Professional#recalculate_open_pricings pula aprovadas), então
  # se o valor da hora-homem/diária mudou no cadastro nesse meio-tempo, reabrir recalcula — e
  # devolve o total antes/depois pra quem chamou AVISAR, nunca mudar o preço em silêncio.
  # Retorna [total_antes, total_depois].
  def reopen!(user:, reason: nil)
    raise ArgumentError, "só proposta aprovada pode ser reaberta" unless status == "approved"

    pricing = project_pricing
    before = pricing.total_value
    transaction do
      update!(status: "priced", reopened_at: Time.current, reopened_by: user, reopen_reason: reason.to_s.strip.presence)
      conversation.update!(status: "pricing") if conversation.status == "completed"
      pricing.recalculate! if pricing.stale_subtotals?
    end
    [ before, pricing.reload.total_value ]
  end

  # A IA monta a equipe a partir do CADASTRO COMPLETO de profissionais ativos (cargo +
  # habilitação), cruzando com tudo que já foi extraído do ET, do TR (quando houver) e dos
  # complementares desta conversa (CLAUDE.md seção 5). Não existe mais "menu" por tipo de estudo
  # (study_templates saiu em 2026-09 — a Papyrus não ia manter esse cadastro): a IA escolhe QUEM
  # entra, O QUE cada um entrega e o esforço (HH + diárias), inclusive da Diretoria/Coordenação.
  # Continua restrita a professional_id real e ativo — nunca inventa gente.
  # Falha/resposta vazia cai em build_base_team! (só Diretoria/Coordenação, 0h).
  def build_with_ai_suggested_team!
    pricing = create_project_pricing!
    suggestion = fetch_ai_team_suggestion
    apply_team_suggestion!(pricing, suggestion)
    update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")

    finalize!(pricing)
  rescue StandardError => e
    Rails.logger.error("build_with_ai_suggested_team! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
    project_pricing&.destroy
    build_base_team!
  end

  # "Reorganizar pela planilha do cliente" (Tela de Precificação): refaz itens e equipe do zero a
  # partir da sugestão da IA, agora espelhando a lista de preços do cliente. Pede a sugestão ANTES de
  # apagar — se a IA falhar, a precificação atual fica intacta. BDI, logística e parâmetros ficam.
  def rebuild_team_from_client_sheet!
    pricing = project_pricing
    return :no_price_list if client_price_lists.empty?

    suggestion = fetch_ai_team_suggestion
    return :failed if Array(suggestion["itens"]).none? { |item| item.is_a?(Hash) && item["planilha"].is_a?(Hash) }

    transaction do
      pricing.proposal_professionals.destroy_all
      pricing.pricing_items.destroy_all
      pricing.pricing_enterprises.destroy_all
      pricing.pricing_items.reset
      apply_team_suggestion!(pricing, suggestion)
      pricing.recalculate!
    end
    :done
  end

  def client_price_list? = client_price_lists.any?

  # Equipe mínima, sem IA: só os `always_included` (Diretoria/Coordenação) com 0h. Fallback de
  # segurança e o que `Conversation#ensure_proposal!(ai_suggestions: false)` usa de dentro de
  # tool call (IA síncrona ali reentraria `Conversation#complete`) — o resto da equipe vem depois,
  # em background, por `suggest_team_if_missing!` (SuggestTeamJob).
  def build_base_team!
    pricing = create_project_pricing!
    ensure_always_included_lines!(pricing)
    finalize!(pricing)
  end

  # Completa a equipe com a sugestão da IA quando a proposta ainda só tem os `always_included`
  # sem esforço nenhum — o estado que `build_base_team!` deixa. Achado em produção: gerar a
  # proposta direto pelo chat (`GenerateProposalDocumentTool` → `ensure_proposal!(ai_suggestions:
  # false)`) sem passar pela Tela de Precificação deixava a equipe só com Diretoria/Coordenação a
  # 0h, e o consultor via isso como "a equipe não foi mapeada".
  #
  # Idempotente e seguro: não age se já existe qualquer linha além dos fixos, nem se o consultor
  # já deu horas/diárias a um fixo — nunca reescreve o que a IA sugeriu antes nem o que o
  # consultor ajustou. Roda em BACKGROUND (SuggestTeamJob), nunca síncrono dentro da tool call.
  def suggest_team_if_missing!
    pricing = project_pricing
    return unless pricing
    return unless team_untouched?(pricing)

    suggestion = fetch_ai_team_suggestion
    return if suggestion.blank?

    apply_team_suggestion!(pricing, suggestion)
    update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")
    pricing.recalculate!
  rescue StandardError => e
    Rails.logger.error("suggest_team_if_missing! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
  end

  # Equipe no estado de `build_base_team!`: só os fixos, todos sem esforço. Usado por
  # GenerateProposalDocumentTool#ensure_team_background_work! pra decidir se enfileira
  # SuggestTeamJob, e pelo próprio `suggest_team_if_missing!`.
  def team_untouched?(pricing = project_pricing)
    return false unless pricing

    lines = pricing.proposal_professionals.includes(:professional).to_a
    lines.all? { |line| line.professional.always_included && line.man_hours.zero? && line.field_days.zero? }
  end

  # Mesmo mecanismo de `with_schedule_lock`, namespace PRÓPRIO (classid diferente) — serializa
  # SuggestTeamJob contra outra chamada concorrente pra MESMA proposta, sem colidir com a trava do
  # cronograma (as duas podem rodar em paralelo pra propostas diferentes, ou até pra fases
  # diferentes da MESMA proposta, sem se esperar uma pela outra à toa).
  TEAM_LOCK_NAMESPACE = 982453
  private_constant :TEAM_LOCK_NAMESPACE

  def with_team_lock(&block)
    self.class.transaction do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(#{TEAM_LOCK_NAMESPACE}, #{id.to_i})")
      block.call
    end
  end

  # SuggestScheduleJob/ElectScheduleKeyPointsJob rodam FORA da conversa que pediu a geração (ver
  # comentário nos dois), então mais de um pode ser enfileirado pra a MESMA proposta antes que o
  # primeiro termine — achado ao vivo (chat 32, 2026-09, "saiu muita coisa repetida no
  # cronograma"): duas chamadas de "gerar cronograma" a ~40s de distância passaram as duas pela
  # checagem "já existe item?" (feita ANTES da chamada à IA, que sozinha leva dezenas de segundos)
  # enquanto nenhuma tinha inserido nada ainda, e as duas rodaram build_with_ai_suggested_schedule!
  # em paralelo — cada uma criando o cronograma inteiro do zero (position reiniciando em 0), a
  # tabela final saiu com cada atividade duplicada numa paráfrase diferente (duas chamadas de IA
  # distintas, não a mesma inserida 2x). `with_schedule_lock` serializa os dois jobs pela MESMA
  # proposta com pg_advisory_xact_lock — quem chega depois espera o commit de quem já está
  # rodando e então repete a própria checagem "já existe?", agora vendo o resultado da primeira
  # chamada e desistindo. Namespace próprio (classid fixo, forma de 2 argumentos) pra não colidir
  # com o pg_advisory_xact_lock(conversation.id) de Conversation#with_ai_lock — id de proposta e
  # id de conversa são sequências independentes que podem coincidir numericamente (a proposta 18
  # desta mesma conversa 32 é um exemplo real). Libera sozinho no commit/rollback, mesmo mecanismo
  # de sempre.
  SCHEDULE_LOCK_NAMESPACE = 982451
  private_constant :SCHEDULE_LOCK_NAMESPACE

  def with_schedule_lock(&block)
    self.class.transaction do
      self.class.connection.execute("SELECT pg_advisory_xact_lock(#{SCHEDULE_LOCK_NAMESPACE}, #{id.to_i})")
      block.call
    end
  end

  # Sugere fases/atividades do cronograma a partir do que já foi extraído do ET/TR nesta
  # conversa (CLAUDE.md seção 8). Diferente da equipe técnica, não existe "menu" de fases por
  # tipo de estudo — é conteúdo livre, então não passa por catálogo/apply_lines!, só parse +
  # persistência direta. Chamado depois de build_with_ai_suggested_team!/build_base_team!
  # (precisa de project_pricing já criado).
  #
  # A IA nunca sugere a DATA de início (schedule_*_start_date) — isso é sempre o consultor quem
  # digita na Tela de Precificação, é ele quem sabe a data combinada com o cliente.
  #
  # Sem fallback determinístico: não existe "template padrão" de cronograma. Falha ou resposta
  # vazia só significa que a proposta nasce sem cronograma nenhum — o consultor monta na mão se
  # quiser (mesmo botão "Adicionar linha" que já existe pra equipe/custos externos). Nunca
  # bloqueia a criação da proposta.
  def build_with_ai_suggested_schedule!
    pricing = project_pricing
    return unless pricing

    suggestion = fetch_ai_schedule_suggestion
    apply_schedule_lines!(pricing, "servico", Array(suggestion["cronograma_servico"]))
    apply_schedule_lines!(pricing, "implantacao", Array(suggestion["cronograma_implantacao"]))
    pricing.update!(schedule_key_points: parse_schedule_key_points(suggestion))
  rescue StandardError => e
    Rails.logger.error("build_with_ai_suggested_schedule! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
  end

  # Reconstrói o cronograma do ZERO a partir de uma nova sugestão da IA — chamado quando o
  # consultor pede uma MUDANÇA num cronograma que a proposta JÁ TEM (ex.: "mude para 6 meses"),
  # nunca automaticamente. Achado em produção (conversa 44): sem isto, a IA só tinha
  # `generate_proposal_document` pra "atualizar" o cronograma, mas essa ferramenta só LÊ
  # `schedule_items` do banco pra montar o .docx — nunca escreve neles. A IA respondia "cronograma
  # atualizado para 6 meses" três vezes seguidas (inclusive depois do consultor apontar a
  # inconsistência) sem NENHUMA mudança real acontecer: os mesmos 24 itens de 12 meses/52 semanas
  # continuavam no banco, intocados, e cada nova geração renderizava exatamente o mesmo gráfico de
  # antes.
  #
  # Diferente de `build_with_ai_suggested_schedule!` (só roda quando não há item nenhum — nunca
  # reescreve o que o consultor já ajustou), este método SEMPRE apaga o cronograma inteiro e
  # substitui pela nova sugestão — é uma ação explícita, só disparada quando o consultor pede uma
  # mudança de verdade (`GenerateProposalDocumentTool` param `atualizar_cronograma`). A chamada à
  # IA (`fetch_ai_schedule_suggestion`) lê o histórico completo da conversa via `ask_internally`,
  # então o pedido de mudança mais recente do consultor já está no contexto que ela vê.
  #
  # Roda em background (RegenerateScheduleJob), pelo mesmo motivo de sempre: esta ferramenta é
  # chamada como tool call DENTRO de Conversation#complete, e uma chamada de IA síncrona aqui
  # reentraria complete/ask_internally (ver build_with_ai_suggested_schedule!/CLAUDE.md seção 8).
  #
  # Só apaga o cronograma ATUAL quando a IA devolve algo (`suggestion.blank?` cobre resposta que
  # não parseou como JSON — `fetch_ai_schedule_suggestion` devolve `{}` nesse caso). Diferente de
  # `build_with_ai_suggested_schedule!` (falha aí não perde nada, porque não havia nada antes),
  # aqui existe um cronograma FUNCIONANDO pra proteger — uma falha de parse nunca deve trocar um
  # cronograma bom por um vazio.
  def regenerate_schedule!
    pricing = project_pricing
    return unless pricing

    suggestion = fetch_ai_schedule_suggestion
    return if suggestion.blank?

    pricing.schedule_items.destroy_all
    apply_schedule_lines!(pricing, "servico", Array(suggestion["cronograma_servico"]))
    apply_schedule_lines!(pricing, "implantacao", Array(suggestion["cronograma_implantacao"]))
    pricing.update!(schedule_key_points: parse_schedule_key_points(suggestion))
  rescue StandardError => e
    Rails.logger.error("regenerate_schedule! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
  end

  # Elege os ≤6 marcos do infográfico de linha do tempo (CLAUDE.md seção 8) a partir de um
  # cronograma_servico que JÁ EXISTE — proposta antiga (criada antes desta funcionalidade), ou
  # cronograma que o consultor montou/ajustou à mão na Tela de Precificação. `build_with_ai_
  # suggested_schedule!` só roda quando não há item nenhum, então sem isto uma proposta com
  # cronograma nunca ganharia os marcos e o infográfico ficaria pra sempre no fallback de fase.
  # Só toca `schedule_key_points`; nunca mexe nos `schedule_items`. Roda SEMPRE em background
  # (ElectScheduleKeyPointsJob) pelo mesmo motivo de build_with_ai_suggested_schedule! —
  # reentrância de Conversation#complete.
  def elect_schedule_key_points!
    pricing = project_pricing
    return unless pricing

    items = pricing.schedule_items.for_type("servico").to_a
    return if items.empty?

    suggestion = fetch_ai_key_points_suggestion(items)
    pricing.update!(schedule_key_points: parse_schedule_key_points(suggestion))
  rescue StandardError => e
    Rails.logger.error("elect_schedule_key_points! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
  end

  # Seleção determinística de até 6 marcos quando a IA ainda não elegeu os marcos em background
  # (proposta antiga, ou primeira geração síncrona antes do job concluir). Garante que o
  # infográfico NUNCA saia com dezenas de círculos, mesmo antes do job rodar.
  def default_schedule_key_points
    pricing = project_pricing
    return [] unless pricing

    items = pricing.schedule_items.for_type("servico").to_a
    return [] if items.empty?

    self.class.default_key_points_from(items)
  end

  def self.default_key_points_from(items)
    items = Array(items).sort_by { |item| [ item.start_period.to_i, item.position.to_i ] }
    return [] if items.empty?

    # 1. Pega itens marcados como marco (milestone: true)
    milestones = items.select(&:milestone?)

    # 2. Sempre inclui o primeiro (início/kick-off) e o último (conclusão/emissão)
    candidates = []
    candidates << items.first if items.first
    candidates.concat(milestones)
    candidates << items.last if items.last
    candidates.uniq!

    # 3. Se ainda há menos de 6, inclui o início de fases distintas
    if candidates.size < 6
      items.group_by(&:phase_name).each_value do |phase_items|
        break if candidates.size >= 6
        first_in_phase = phase_items.first
        candidates << first_in_phase unless candidates.include?(first_in_phase)
      end
    end

    # 4. Ordena cronologicamente
    ordered = candidates.sort_by { |item| [ item.start_period.to_i, item.position.to_i ] }

    # 5. Se houver mais de 6 (muitos marcos explícitos), mantém primeiro, último e amostra os intermediários
    if ordered.size > 6
      first = ordered.first
      last = ordered.last
      middle = ordered[1...-1]
      step = (middle.size.to_f / 4).ceil
      sampled = middle.each_slice([ step, 1 ].max).map(&:first).first(4)
      ordered = [ first, *sampled, last ].uniq.sort_by { |item| [ item.start_period.to_i, item.position.to_i ] }
    end

    ordered.first(6).map do |item|
      { "nome" => item.activity_name.to_s.truncate(45), "periodo" => [ item.start_period.to_i, 1 ].max }
    end
  end

  private
    def standard_filename_base(kind)
      partes = [ conversation.client_name, ato_licenciamento, nome_projeto ]
        .map { |texto| sanitize_for_filename(texto) }.compact_blank

      "#{docx_numero_proposta(kind)}_#{partes.join('_')}"
    end

    # Sigla mais curta que o "achado" tipo_licenca costuma trazer é geralmente já a sigla mesma
    # (ex.: "(LP)", "LP+LI") — mas nem sempre: às vezes a IA escreve por extenso ("Licença Prévia
    # e Licença de Instalação", achado real). Extrai as siglas que já estiverem no texto; se não
    # achar nenhuma, tenta casar contra os nomes completos mais comuns. Junta tudo achado em TODOS
    # os achados ativos (podem vir em registros separados, um por ato) com "+", sem repetir —
    # mesma convenção "LP+LI" já usada de verdade pela Papyrus.
    LICENSE_ACT_ACRONYM_PATTERN = /\b([A-Z]{2,4})\b/
    LICENSE_ACT_NAMES = {
      "licença prévia" => "LP", "licença de instalação" => "LI", "licença de operação" => "LO",
      "renovação da licença de operação" => "RLO", "renovação da licença prévia" => "RLP",
      "licença unificada" => "LU", "licença de alteração" => "LA", "licença de regularização" => "LR",
      "autorização de supressão de vegetação" => "ASV", "autorização de manejo florestal" => "AMF",
      "dispensa de licença ambiental" => "DLA", "autorização ambiental" => "AA"
    }.freeze

    def ato_licenciamento
      license_act_acronyms.presence&.join("+")
    end

    def license_acronyms_in(texto)
      diretas = texto.scan(LICENSE_ACT_ACRONYM_PATTERN).flatten
      return diretas if diretas.any?

      texto_normalizado = texto.downcase
      LICENSE_ACT_NAMES.select { |nome, _sigla| texto_normalizado.include?(nome) }.values
    end

    # "Nome do projeto" (achado `empreendimento`, ex.: "BESS São Desidério") — sem sigla pra
    # normalizar, então quando só existe a frase técnica inteira (a descrição completa do
    # empreendimento, comum vir só do ET) e nenhuma versão curta, omite o segmento em vez de
    # truncar no meio de uma palavra — nome de arquivo incompleto mas limpo é melhor que completo
    # e cortado feio; o consultor sempre pode ditar o nome exato no chat (docx_filename_override).
    NOME_PROJETO_LIMIT = 40

    def nome_projeto
      valor = conversation.project_findings.active.where(field: "empreendimento")
        .min_by { |finding| [ finding.value.length, ProjectFinding::SOURCE_KINDS.keys.index(finding.source_kind) || 99 ] }
        &.value
      valor if valor.present? && valor.length <= NOME_PROJETO_LIMIT
    end

    # O consultor ditou o nome; o sistema só cuida do que distingue os DOIS arquivos quando a
    # proposta sai separada em técnica e comercial — senão os dois sairiam com o mesmo nome.
    # Quando o nome dele já começa pelo número da proposta, trocar PTC/PT/PC é a própria
    # convenção da Papyrus; quando não começa, o sufixo é o jeito de não colidir.
    def custom_filename_base(kind)
      name = sanitize_for_filename(docx_filename_override).to_s.sub(/\.docx\z/i, "").strip
      return name if kind == "combined"
      return name.sub(/\A(PTC|PT|PC)/i, DOCX_NUMERO_PREFIXES.fetch(kind, "PTC")) if name.match?(NUMBER_PREFIX)

      "#{name}_#{kind == "tecnica" ? "Tecnica" : "Comercial"}"
    end

    def sanitize_for_filename(text)
      text.to_s.gsub(%r{[/\\:*?"<>|]}, "-").presence
    end

    def formatted_date(value)
      Date.parse(value.to_s).strftime("%d/%m/%Y")
    rescue Date::Error, TypeError
      ""
    end

    def number_br(value)
      ActionController::Base.helpers.number_with_precision(value.to_d, precision: 2, separator: ",", delimiter: ".", strip_insignificant_zeros: true)
    end

    def format_currency(value)
      ActionController::Base.helpers.number_to_currency(value, unit: "", separator: ",", delimiter: ".").strip
    end

    # "40" quando o percentual for inteiro, "37,5" (vírgula, padrão PT-BR) quando não.
    def format_percentage(value)
      numero = value.to_f
      return numero.to_i.to_s if (numero % 1).zero?

      numero.to_s.sub(".", ",")
    end

    # "renovação da licença prévia" (chave de LICENSE_ACT_NAMES) → "Renovação da Licença Prévia".
    # Conectores curtos ("de"/"da") ficam minúsculos, exceto na 1ª palavra — regra simples de
    # título em português, não é I18n/titleize genérico (que não conhece essas exceções).
    LICENSE_ACT_NAME_CONNECTORS = %w[de da].freeze

    def humanize_license_act_name(texto)
      texto.split(" ").each_with_index.map do |palavra, i|
        i.positive? && LICENSE_ACT_NAME_CONNECTORS.include?(palavra) ? palavra : palavra.capitalize
      end.join(" ")
    end

    def finalize!(pricing)
      pricing.recalculate!
      pricing
    end

    # "Tipo(s) de estudo identificado(s)" pro prompt de equipe — contexto, não restrição.
    def study_types_context
      names = conversation.study_types.order(:name).pluck(:name)
      return "Nenhum tipo de estudo específico foi associado (proposta de acompanhamento/assessoria)." if names.empty?

      "Tipo(s) de estudo desta proposta: #{names.join(', ')}."
    end

    # SETOR derivado (sem cadastro novo): Diretoria = always_included com "diretor" no cargo;
    # Gestão = os demais always_included (Coordenação/Gestão da Papyrus); Execução = o resto.
    def docx_team_sector(professional)
      return :execucao unless professional.always_included
      return :diretoria if professional.role.to_s.downcase.include?("diretor")

      :gestao
    end

    def docx_team_sector_label(professional)
      { diretoria: "Diretoria", gestao: "Gestão", execucao: "Execução" }.fetch(docx_team_sector(professional))
    end

    # `tools: true`: a IA pode ver no acervo como a Papyrus montou a equipe em projetos parecidos
    # antes de sugerir (ferramentas de Conversation#internal_tools).
    def fetch_ai_team_suggestion
      conversation.ask_internally(team_suggestion_prompt, hide_response: true, temperature: 0, tools: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    # Equipes de projetos anteriores parecidos (JobPrecedent), entregues de uma vez no prompt de
    # equipe — em vez de depender da IA lembrar de chamar a ferramenta (2026-09-27, avaliação do
    # RAG: nas conversas reais ela buscava "equipe… horas homem diárias…" em texto corrido e não
    # achava). Referência de COMPOSIÇÃO e ESFORÇO; os nomes eram de quem estava na época.
    def precedent_teams_context
      matches = Rag::PrecedentFinder.new.call(conversation.service_descriptor, limit: 3)
      return "" if matches.empty?

      lines = matches.map do |match|
        precedent = match.precedent
        team = precedent.team_members.map do |member|
          effort = [ ("#{member['horas_homem'].to_f.round} HH" if member["horas_homem"]), ("#{member['diarias'].to_f.round} diárias" if member["diarias"]) ].compact.join(", ")
          [ member["funcao"], effort.presence&.then { "(#{_1})" } ].compact.join(" ")
        end.join("; ")
        "- #{precedent.reference} — #{precedent.service.to_s.truncate(140)}#{"; prazo #{precedent.duration.truncate(60)}" if precedent.duration}: #{team}"
      end

      <<~TEXT.strip
        EQUIPES DE PROJETOS ANTERIORES PARECIDOS DA PAPYRUS (referência de composição e esforço —
        quais frentes costumam entrar e quanto esforço cada uma levou; escolha as pessoas pelo
        quadro atual abaixo, não pelos nomes antigos):
        #{lines.join("\n")}
      TEXT
    rescue StandardError => e
      Rails.logger.warn("[Proposal] precedentes de equipe indisponíveis: #{e.class} #{e.message}")
      ""
    end

    # O que o ET/TR disse sobre como apresentar o preço (achado "apresentacao_preco") — entregue
    # no prompt de equipe porque a IA ali não relê o PDF original, só a conversa.
    def price_presentation_context
      notes = conversation.project_findings.active.where(field: "apresentacao_preco").pluck(:value, :excerpt)
      return "" if notes.empty?

      lines = notes.map { |value, excerpt| "- #{value}#{" (trecho: \"#{excerpt}\")" if excerpt.present?}" }
      "O que os documentos desta proposta dizem sobre a apresentação do preço:\n#{lines.join("\n")}"
    end

    # Lista de preços do cliente (PPU, planilha de quantitativos) anexada: a precificação ESPELHA os
    # itens dela, com as quantidades DELE (2026-09-30, conversa 65: a PPU pedia 2.994 diárias
    # embarcadas e a equipe estimada pelo escopo tinha 600 — a diária saiu a R$ 71). Só entram abas
    # com cara de lista de preços, e com teto de tamanho (a DFP inteira não cabe nem ajuda aqui).
    PRICE_LIST_PATTERN = /pre[çc]o\s+unit|valor\s+unit|unit[áa]rio/i
    QUANTITY_PATTERN = /quantidade|\bqtd|\bquant\./i
    PRICE_LIST_MAX_CHARS = 14_000

    def client_price_lists
      @client_price_lists ||= SpreadsheetFill.client_spreadsheets(conversation).filter_map do |attachment|
        workbook = Spreadsheets::Workbook.open(attachment.blob.download)
        # Aba visível com preço unitário E quantidade (as abas ocultas de uma DFP também dizem
        # "valor unitário", mas são formação de custo, não a lista que o cliente mede).
        sheets = workbook.sheets.select do |sheet|
          texts = workbook.cells(sheet.name).map { |cell| cell.value.to_s }
          sheet.state == "visible" && texts.any? { |text| text.match?(PRICE_LIST_PATTERN) } && texts.any? { |text| text.match?(QUANTITY_PATTERN) }
        end
        next if sheets.empty?

        text = workbook.to_prompt_text(only: sheets.map(&:name), max_cells_per_sheet: 250)
        { attachment: attachment, workbook: workbook, text: text }
      rescue Spreadsheets::Workbook::Error, Zip::Error
        nil
      end
    end

    def client_price_lists_context
      return "" if client_price_lists.empty?

      budget = PRICE_LIST_MAX_CHARS
      sheets = client_price_lists.map do |list|
        text = list[:text].truncate([ budget, 500 ].max)
        budget -= text.size
        "#### Arquivo \"#{list[:attachment].filename}\" (blob_id #{list[:attachment].blob_id})\n#{text}"
      end
      <<~TEXT
        LISTA DE PREÇOS DO CLIENTE: o cliente mandou a(s) planilha(s) abaixo, com itens e QUANTIDADES
        que ele vai medir e pagar (PPU/planilha de quantitativos). Nesse caso os itens da proposta
        ESPELHAM a lista dele:
        - Um item pra cada linha da lista que tem PREÇO UNITÁRIO a preencher (não pra títulos de
          grupo nem totais), com "nome" = a descrição do cliente e "planilha" = { "blob_id", "aba",
          "codigo" (ex.: "1.1"), "unidade" (ex.: "diária por pessoa"), "celula_preco" (a célula do
          preço unitário), "celula_quantidade" (a célula da quantidade) }. A QUANTIDADE é lida pelo
          sistema na planilha — não a informe.
        - Nesses itens, o esforço da equipe é POR UNIDADE do cliente: "man_hours_por_unidade" e
          "field_days_por_unidade" (quanto 1 diária, 1 relatório, 1 poço consome). Se várias pessoas
          se revezam numa mesma unidade (ex.: "diária por pessoa" coberta por 4 observadores em
          rodízio), divida entre elas (0,25 cada) — o total tem que dar exatamente 1 pessoa-dia por
          diária. Nunca use o esforço total do contrato.
        - Custos que a unidade consome (passagem por troca de turma, kit de equipamentos, curso
          HUET/CBSP, hospedagem antes do embarque…) vão em "custos": [{ "descricao",
          "quantidade_por_unidade" }] — só a quantidade; o valor em R$ o consultor preenche.
        - Gestão/coordenação que atravessa o contrato pode ficar num item SEM "planilha" (esforço
          total, como sempre): o sistema rateia o custo dele entre os itens do cliente.
        - Dúvida que muda o dimensionamento: registre a interpretação no "deliverable_name".
        #{sheets.join("\n\n")}
      TEXT
    end

    def team_suggestion_prompt
      describe = lambda do |professional|
        "- professional_id: #{professional.id} | #{professional.name} (#{professional.role}) | " \
        "habilitação: #{professional.specialties.presence || '—'}" \
        "#{' | CUSTO NO BDI: entra só com o papel, man_hours e field_days = 0' if professional.cost_in_bdi?}"
      end
      active = Professional.active.order(:name).to_a
      fixed, roster = active.partition(&:always_included)

      <<~TEXT
        Você monta a composição de equipe de uma proposta de consultoria ambiental da Papyrus,
        com base em tudo que já foi analisado nesta conversa (ET, TR quando houver, documentos
        complementares e propostas anteriores semelhantes, se houver). #{study_types_context}
        #{precedent_teams_context}
        Se a ferramenta search_historical_archive estiver disponível, use-a pra ver como a Papyrus
        dimensionou a equipe em projetos parecidos — referência, não cópia.

        EQUIPE FIXA (entra em toda proposta — inclua uma linha para CADA um, com o papel e o
        esforço dele neste projeto):
        #{fixed.map(&describe).join("\n").presence || "(nenhum)"}

        QUADRO DE PROFISSIONAIS (escolha só quem o escopo realmente exige — diagnósticos,
        geoprocessamento/cartografia, estudos temáticos, análise jurídica, arqueologia etc.):
        #{roster.map(&describe).join("\n").presence || "(nenhum)"}

        Regras:
        - Use só professional_id das listas acima — nunca invente.
        - "deliverable_name" é o entregável/frente de trabalho da pessoa NESTA proposta (ex.:
          "Geoprocessamento e Cartografia", "Diagnóstico do Meio Físico", "Coordenação Geral"),
          sem nome de órgão nem de sistema (nada de "INEMA", "SEI-BAHIA": "órgão ambiental").
        - UMA linha por pessoa em cada item: se ela entrega várias coisas no mesmo item, junte
          num entregável só ("Diagnóstico de Fauna e Avifauna") somando o esforço. A mesma pessoa
          só aparece em outro item quando faz um trabalho de fato diferente lá — nunca divida a
          mesma frente em dois itens (campo de um diagnóstico e a elaboração DELE ficam no mesmo
          item e na mesma linha, com HH e diárias juntos), senão o esforço conta duas vezes.
        - Quem está marcado CUSTO NO BDI (Diretoria) entra na equipe com o papel dele, sempre com
          man_hours e field_days = 0: o custo já está no BDI.
        - Esforço em duas quantidades:
          #{EFFORT_UNITS_GUIDE}
          Estime pelo porte e complexidade do escopo. Se realmente não houver base, use 0 (o
          consultor ajusta na Tela de Precificação), mas ainda assim inclua a linha.

        ORGANIZE A PROPOSTA EM ITENS, como a Papyrus faz na planilha de precificação: cada item é
        uma frente do serviço com a SUA equipe e os SEUS campos (idas a campo). Exemplos reais:
        "Assessoria Ambiental Estratégica", "Estudo Ambiental (EMI) – BESS Irecê", "Participação
        em Reunião Pública", "Estudos Arqueológicos", "Inventário Florestal", "Elaboração de Planos
        e Programas". Use de 1 a 12 itens, conforme o escopo — proposta simples pode ter 1 ou 2.
        - Diretoria/Coordenação/assessoria que atravessa o projeto inteiro vai num item de gestão
          (ex.: "Gestão e Coordenação do Projeto").
        - "campos": cada ida a campo do item, com "descricao" (ex.: "Campo Meio Físico – 01
          geólogo"), "pessoas" (quantas vão), "dias" (dias EM CAMPO, sem contar a viagem),
          "veiculos" e "tipo_veiculo" ("carro" ou "4x4" — 4x4 pra área rural/sem estrada boa). Item
          sem ida a campo fica com "campos": []. Não informe valores em R$: o sistema calcula.
        - EMPREENDIMENTOS: se a proposta cobre MAIS DE UM empreendimento (ex.: três BESS em
          municípios diferentes), liste os nomes em "empreendimentos" e, em cada item específico
          de um deles, informe "empreendimento" com o MESMO nome; itens que valem pra todos ficam
          com "empreendimento": null (o sistema rateia). Um empreendimento só → "empreendimentos": [].

        Diga também se o ET ou o TR exige que a proposta técnica e a comercial sejam apresentadas
        como documentos/envelopes SEPARADOS (comum em licitação) — se nenhum falar nada, considere
        que NÃO (documento único).

        E em "apresentacao_preco", como o ET/TR pede o preço: "total" (preço global — o padrão,
        quando nada é dito), "itens" (custos discriminados por etapa/estudo/item),
        "empreendimentos" (discriminado e com o valor de cada empreendimento) ou "detalhado" (quando
        pede a composição do preço: horas-homem, diárias, logística, BDI e impostos separados, ou uma
        planilha de composição de custos).
        #{price_presentation_context}
        #{client_price_lists_context}

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "empreendimentos": [],
          "itens": [
            {
              "nome": "Diagnóstico do Meio Físico",
              "empreendimento": null,
              "equipe": [
                { "professional_id": 12, "deliverable_name": "Diagnóstico do Meio Físico", "man_hours": 40, "field_days": 2 }
              ],
              "campos": [
                { "descricao": "Campo Meio Físico – 01 geólogo", "pessoas": 1, "dias": 2, "veiculos": 1, "tipo_veiculo": "4x4" }
              ]
            },
            {
              "nome": "Relatório Técnico Consolidado do PMBM",
              "planilha": { "blob_id": 650, "aba": "PPU", "codigo": "2.1", "unidade": "relatório",
                            "celula_preco": "F9", "celula_quantidade": "E9" },
              "equipe": [
                { "professional_id": 20, "deliverable_name": "Relatório do PMBM", "man_hours_por_unidade": 40, "field_days_por_unidade": 0 }
              ],
              "custos": [ { "descricao": "Editoração e impressão", "quantidade_por_unidade": 1 } ],
              "campos": []
            }
          ],
          "apresentacao_preco": "total",
          "documentos_separados": false,
          "justificativa_documentos_separados": "..."
        }
      TEXT
    end

    # `tools: true`: a IA pode consultar o acervo (como a Papyrus estruturou cronogramas
    # parecidos) — as ferramentas vêm de Conversation#internal_tools.
    def fetch_ai_schedule_suggestion
      conversation.ask_internally(schedule_suggestion_prompt, hide_response: true, temperature: 0, tools: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    def schedule_suggestion_prompt
      <<~TEXT
        Com base em tudo que já foi analisado nesta conversa (ET, TR quando houver, documentos
        complementares e propostas anteriores semelhantes, se houver), sugira o cronograma desta
        proposta. Se a ferramenta search_historical_archive estiver disponível, use-a pra ver como
        a Papyrus estruturou o cronograma em projetos anteriores parecidos (mesmo tipo de estudo,
        mesmo tipo de empreendimento) — é referência de fases/duração típicas, não fonte de datas.

        Existem DOIS tipos de cronograma, independentes:

        1. "cronograma_servico" — as atividades do PRÓPRIO SERVIÇO da Papyrus (o estudo/
           licenciamento em si): reuniões, campanhas de campo, elaboração dos estudos, protocolos
           junto ao órgão, emissão da licença. Praticamente toda proposta tem este. Períodos em
           SEMANAS (1, 2, 3...), contadas a partir de uma data de início que o consultor ainda vai
           definir — você não sabe essa data, só a ORDEM e a DURAÇÃO relativa das atividades.

        2. "cronograma_implantacao" — o cronograma de IMPLANTAÇÃO DO EMPREENDIMENTO do CLIENTE
           (obra, construção, entrada em operação) — não é serviço da Papyrus, é do empreendimento
           em si. SÓ preencha isso quando o ET ou o TR pedir explicitamente um cronograma de
           implantação como parte do escopo/produto — não é padrão em toda proposta, deixe a lista
           vazia quando não houver essa exigência. Períodos em MESES (pode durar anos).

        Cada item de cada lista: fase (nome do agrupamento, ex.: "Mobilização"), atividade (nome
        específico, ex.: "Assinatura do Contrato e Kick-Off"), período de início (1-based, semana
        ou mês conforme o tipo), duração (quantos períodos a atividade ocupa, mínimo 1), e se é um
        marco (marco: true/false — um evento pontual, não uma atividade com duração, ex.:
        "Emissão da Licença Prévia"). Agrupe as atividades da mesma fase em sequência na lista.
        Não invente números de dias de campo/vistorias fora do que já está definido nesta
        proposta — se não souber a duração exata, estime de forma razoável a partir do escopo.

        Por fim, em "marcos_infografico", escolha os ATÉ 6 pontos MAIS IMPORTANTES do
        "cronograma_servico" pra um resumo visual (infográfico de linha do tempo que o cliente vê
        de cara): os marcos/entregas que o cliente mais quer acompanhar — assinatura do contrato,
        protocolo no órgão ambiental, emissão de cada licença, e as 1-2 campanhas/entregas mais
        críticas. Do começo ao fim do cronograma, em ordem. Cada um: "nome" (curto, ex.:
        "Protocolo no órgão ambiental") e "periodo" (a semana 1-based do "cronograma_servico" em
        que o marco acontece). No máximo 6 — se o cronograma for pequeno, pode ter menos.

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "cronograma_servico": [
            { "fase": "Mobilização", "atividade": "Assinatura do Contrato e Kick-Off", "periodo_inicio": 1, "duracao": 1, "marco": false }
          ],
          "cronograma_implantacao": [],
          "marcos_infografico": [
            { "nome": "Assinatura do contrato", "periodo": 1 }
          ]
        }
      TEXT
    end

    def fetch_ai_key_points_suggestion(items)
      conversation.ask_internally(key_points_suggestion_prompt(items), hide_response: true, temperature: 0)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    # Igual à chave "marcos_infografico" de schedule_suggestion_prompt, mas sobre um cronograma
    # que JÁ está montado (a IA não sugere fases/durações aqui, só elege os principais pontos do
    # que existe).
    def key_points_suggestion_prompt(items)
      linhas = items.map do |item|
        marca = item.milestone? ? " [MARCO]" : ""
        "- semana #{item.start_period} (dura #{item.duration_periods}): #{item.phase_name} — #{item.activity_name}#{marca}"
      end.join("\n")

      <<~TEXT
        Abaixo está o cronograma do serviço desta proposta, já montado — uma atividade por linha,
        semanas 1-based:

        #{linhas}

        Escolha os ATÉ 6 pontos MAIS IMPORTANTES deste cronograma pra um resumo visual (infográfico
        de linha do tempo que o cliente vê de cara): os marcos/entregas que o cliente mais quer
        acompanhar — assinatura do contrato, protocolo no órgão ambiental, emissão de cada licença,
        e as 1-2 campanhas/entregas mais críticas. Do começo ao fim, em ordem. Cada um: "nome"
        (curto, ex.: "Protocolo no órgão ambiental") e "periodo" (a semana 1-based em que o ponto
        acontece). No máximo 6 — se o cronograma for pequeno, pode ter menos.

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        { "marcos_infografico": [ { "nome": "Assinatura do contrato", "periodo": 1 } ] }
      TEXT
    end

    def apply_schedule_lines!(pricing, schedule_type, lines)
      lines.each_with_index do |line, index|
        fase = line["fase"].to_s.strip
        atividade = line["atividade"].to_s.strip
        periodo_inicio = line["periodo_inicio"].to_i
        duracao = line["duracao"].to_i
        next if fase.blank? || atividade.blank? || periodo_inicio < 1 || duracao < 1

        pricing.schedule_items.create!(
          schedule_type: schedule_type, phase_name: fase, activity_name: atividade,
          start_period: periodo_inicio, duration_periods: duracao,
          milestone: line["marco"] == true, position: index
        )
      end
    end

    # Os ≤6 marcos que a IA elegeu pra o infográfico de linha do tempo (só do cronograma_servico).
    # Descarta entrada sem nome ou sem semana válida, ordena por período e corta em 6 — o
    # ScheduleTimelineRenderer também clampa o período contra o fim real do cronograma, então aqui
    # basta a higiene básica. Vazio/ausente → [] (o infográfico cai no resumo por fase).
    def parse_schedule_key_points(suggestion)
      Array(suggestion["marcos_infografico"]).filter_map do |marco|
        nome = marco["nome"].to_s.strip
        periodo = marco["periodo"].to_i
        next if nome.blank? || periodo < 1

        { "nome" => nome, "periodo" => periodo }
      end.sort_by { |marco| marco["periodo"] }.first(6)
    end

    # Grava a sugestão de equipe da IA no formato por ITEM (2026-09-28): empreendimentos, itens
    # (com equipe e campos) e a forma do quadro de preço. Aceita também o formato antigo, uma lista
    # plana em "linhas" (vai tudo pro item padrão). Os fixos que a IA não citou entram no primeiro
    # item (ensure_always_included_lines!); o item padrão que ficou vazio sai.
    def apply_team_suggestion!(pricing, suggestion)
      enterprises = Array(suggestion["empreendimentos"]).filter_map { |name| name.to_s.strip.presence }.uniq.each_with_index.to_h do |name, index|
        [ name.downcase, pricing.pricing_enterprises.find_or_create_by!(name: name) { |e| e.position = index } ]
      end

      items = Array(suggestion["itens"]).select { |item| item.is_a?(Hash) }
      if items.empty?
        apply_team_lines!(pricing, Array(suggestion["linhas"]), pricing.default_item)
      else
        next_position = pricing.pricing_items.maximum(:position).to_i + 1
        items.each_with_index do |data, index|
          name = data["nome"].to_s.strip.truncate(120).presence || "Item #{index + 1}"
          item = pricing.pricing_items.detect { |existing| existing.name.casecmp?(name) } ||
            pricing.pricing_items.create!(name: name, position: next_position + index)
          item.update!(pricing_enterprise: enterprises[data["empreendimento"].to_s.strip.downcase], **mirror_attributes(data["planilha"]))
          apply_team_lines!(pricing, Array(data["equipe"]), item)
          apply_campaigns!(pricing, item, Array(data["campos"]))
          apply_item_costs!(item, Array(data["custos"]))
        end
        drop_empty_default_item!(pricing)
      end

      ensure_always_included_lines!(pricing)
      presentation = suggestion["apresentacao_preco"].to_s
      presentation = "itens" if presentation.blank? && suggestion["preco_discriminado"] == true
      pricing.update!(price_presentation: presentation) if ProjectPricing::PRICE_PRESENTATIONS.key?(presentation) && presentation != "total"
    end

    # Item que espelha uma linha da lista de preços do cliente. A quantidade vem da CÉLULA da
    # planilha (Ruby), nunca da IA; célula sem número deixa o item comum (e registra achado).
    def mirror_attributes(sheet)
      return {} unless sheet.is_a?(Hash)

      list = client_price_lists.find { |candidate| candidate[:attachment].blob_id == sheet["blob_id"].to_i } || client_price_lists.first
      return {} unless list

      quantity = begin
        list[:workbook].value(sheet["aba"], sheet["celula_quantidade"])
      rescue Spreadsheets::Workbook::Error
        nil
      end
      unless quantity.is_a?(Numeric) && quantity.positive?
        conversation.project_findings.create!(
          field: "outro", value: "Item da planilha do cliente sem quantidade legível (#{sheet['aba']}!#{sheet['celula_quantidade']}) — ficou como item comum.",
          nature: "sugestao", source_kind: "sistema"
        )
        return {}
      end

      { client_quantity: quantity, client_unit: sheet["unidade"].to_s.strip.truncate(60).presence,
        client_code: sheet["codigo"].to_s.strip.truncate(20).presence,
        client_sheet: { "blob_id" => list[:attachment].blob_id, "aba" => sheet["aba"].to_s,
                        "celula_preco" => sheet["celula_preco"].to_s.upcase, "celula_quantidade" => sheet["celula_quantidade"].to_s.upcase } }
    end

    # Custos que a IA listou pro item: descrição e QUANTIDADE (por unidade do cliente, quando o item
    # espelha a planilha — o Ruby multiplica). O valor unitário fica 0 pro consultor preencher:
    # preço de passagem, kit ou curso não é conta da IA.
    def apply_item_costs!(item, costs)
      rows = costs.filter_map do |cost|
        next unless cost.is_a?(Hash) && cost["descricao"].to_s.strip.present?

        per_unit = cost["quantidade_por_unidade"] || cost["quantidade"]
        quantity = item.mirrored? && cost.key?("quantidade_por_unidade") ? per_unit.to_d * item.client_quantity : per_unit.to_d
        { "description" => cost["descricao"].to_s.strip.truncate(120), "quantity" => [ quantity.round(2), 0 ].max.to_f, "unit_value" => 0.0 }
      end
      item.update!(costs: item.costs + rows) if rows.any?
    end

    # Campos sugeridos pela IA: ela diz quem vai, quantos dias e com que veículo; o resto sai de
    # regra do sistema — dias de deslocamento pela duração da viagem, 2 pedágios e 1 lavagem por
    # veículo e 2 corridas de Uber quando há estrada (padrão da planilha da Papyrus).
    def apply_campaigns!(pricing, item, campaigns)
      road = pricing.distance_km.positive?
      campaigns.each_with_index do |data, index|
        next unless data.is_a?(Hash)

        vehicles = [ data["veiculos"].to_i, 1 ].max
        item.field_campaigns.create!(
          description: data["descricao"].to_s.strip.truncate(120).presence || "Campo",
          people: [ data["pessoas"].to_i, 1 ].max,
          days: [ data["dias"].to_f, 0 ].max,
          travel_days: pricing.default_travel_days,
          vehicles: vehicles,
          vehicle_type: FieldCampaign::VEHICLE_TYPES.key?(data["tipo_veiculo"].to_s) ? data["tipo_veiculo"].to_s : "carro",
          tolls: road ? 2 * vehicles : 0,
          washes: vehicles,
          uber_trips: road ? 2 : 0,
          position: index
        )
      end
    end

    def drop_empty_default_item!(pricing)
      pricing.pricing_items.reload.each do |item|
        next unless item.name == ProjectPricing::DEFAULT_ITEM_NAME && pricing.pricing_items.size > 1
        next if item.proposal_professionals.exists? || item.field_campaigns.exists? || item.costs.present?

        item.destroy!
      end
      pricing.pricing_items.reset
    end

    # Valida cada linha contra o cadastro (professional_id ativo e real; entregável não vazio) e
    # descarta duplicata (mesmo profissional + mesmo entregável). Linha de um profissional FIXO
    # reaproveita a linha-placeholder dele (papel como entregável, 0h — deixada por
    # build_base_team!) em vez de criar outra ao lado — e passa pro item da sugestão.
    # A mesma pessoa duas vezes no MESMO item vira uma linha só (2026-09-30, conversa 65: Maria e
    # Francisco com duas linhas cada no mesmo item) — soma o esforço e junta os entregáveis. Quem
    # tem o custo no BDI entra sempre com 0 HH/diárias.
    def apply_team_lines!(pricing, lines, item)
      valid = Professional.active.index_by(&:id)
      seen = pricing.proposal_professionals.pluck(:professional_id, :deliverable_name)
        .map { |id, name| [ id, name.to_s.strip.downcase ] }.to_set

      lines.each do |line|
        professional = valid[line["professional_id"].to_i]
        deliverable = line["deliverable_name"].to_s.strip
        next flag_out_of_catalog(line) if professional.nil? || deliverable.blank?

        key = [ professional.id, deliverable.downcase ]
        next if seen.include?(key)

        seen << key
        man_hours, field_days = professional.cost_in_bdi? ? [ 0, 0 ] : [ effort(line["man_hours"]), effort(line["field_days"]) ]
        attrs = { deliverable_name: deliverable, pricing_item: item, man_hours: man_hours, field_days: field_days }
        if item.mirrored? # esforço POR UNIDADE do cliente; ProposalProfessional multiplica pela quantidade
          per_unit = professional.cost_in_bdi? ? [ 0, 0 ] : [ effort(line["man_hours_por_unidade"]), effort(line["field_days_por_unidade"]) ]
          attrs.merge!(man_hours_per_unit: per_unit[0], field_days_per_unit: per_unit[1], man_hours: 0, field_days: 0)
        end
        placeholder = if professional.always_included
          pricing.proposal_professionals.find_by(professional: professional, deliverable_name: professional.role, man_hours: 0, field_days: 0)
        end
        same_item = pricing.proposal_professionals.where(professional: professional, pricing_item: item).where.not(id: placeholder&.id).first

        if same_item
          merged = [ same_item.deliverable_name, deliverable ].uniq { |name| name.strip.downcase }.join("; ").truncate(255)
          if item.mirrored?
            same_item.update!(deliverable_name: merged, man_hours_per_unit: same_item.man_hours_per_unit.to_d + attrs[:man_hours_per_unit],
                              field_days_per_unit: same_item.field_days_per_unit.to_d + attrs[:field_days_per_unit])
          else
            same_item.update!(deliverable_name: merged, man_hours: same_item.man_hours + man_hours, field_days: same_item.field_days + field_days)
          end
        elsif placeholder
          placeholder.update!(attrs)
        else
          pricing.proposal_professionals.create!(attrs.merge(professional: professional))
        end
      end
    end

    def effort(value)
      [ value.to_f, 0 ].max
    end

    # Profissionais fixos (professionals.always_included — Diretoria/Coordenação da Papyrus)
    # entram em TODA proposta: a IA pode não sugerir a linha de um deles, e isso não pode fazer
    # um fixo sumir da equipe — a garantia é do sistema, não da sugestão. Sem sugestão, entra com
    # o cargo como entregável e 0h; o consultor ajusta na Tela de Precificação.
    def ensure_always_included_lines!(pricing)
      present = pricing.proposal_professionals.distinct.pluck(:professional_id).to_set

      Professional.active.always_included.find_each do |professional|
        next if present.include?(professional.id)

        pricing.proposal_professionals.create!(
          professional: professional, deliverable_name: professional.role, man_hours: 0, field_days: 0
        )
      end
    end

    def flag_out_of_catalog(line)
      professional = Professional.find_by(id: line["professional_id"])
      descricao = [ professional&.name || "profissional ##{line['professional_id']}",
                    line["deliverable_name"].presence ].compact_blank.join(" — ")

      conversation.project_findings.create!(
        field: "outro", nature: "sugestao", source_kind: "sistema",
        value: "sugestão de equipe fora do cadastro: #{descricao}",
        excerpt: "A IA sugeriu este profissional para a equipe, mas o professional_id não existe ou está inativo no cadastro (ou veio sem entregável). Não entrou na precificação."
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Proposal] não consegui registrar sugestão fora do cadastro: #{e.message}")
    end
end
