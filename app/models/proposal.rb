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
    conversation.project_findings.active.where(field: "tipo_licenca").pluck(:value)
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

  def team_rows_for_docx
    lines = project_pricing&.proposal_professionals&.includes(:professional)&.to_a || []

    lines
      .sort_by { |line| [ DOCX_TEAM_SECTORS.fetch(docx_team_sector(line.professional)), line.professional.name.to_s ] }
      .map do |line|
        professional = line.professional
        habilitacao = [ professional.specialties.presence, professional.registration.presence ].compact.join(" — ")
        [ docx_team_sector_label(professional), line.deliverable_name.to_s, professional.name.to_s, habilitacao ]
      end
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

  # Linha do Quadro de Preço (N° | SERVIÇO | PREÇO R$, reintroduzido em 2026-09 a pedido do
  # consultor) — sempre 1 linha só, o sistema calcula um preço TOTAL por proposta, nunca por
  # serviço/entregável separado (ver seção 5, motor de precificação). `descricao_fallback` é o
  # texto livre que a IA já escreve pra outros fins (descricao_servico) — só entra quando não dá
  # pra derivar um nome determinístico do ato de licenciamento (ver #docx_servico_label).
  def docx_price_rows(descricao_fallback: nil)
    [ [ docx_servico_label(fallback: descricao_fallback), format_currency(project_pricing.total_value) ] ]
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
    apply_team_lines!(pricing, Array(suggestion["linhas"]))
    ensure_always_included_lines!(pricing)
    update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")

    finalize!(pricing)
  rescue StandardError => e
    Rails.logger.error("build_with_ai_suggested_team! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
    project_pricing&.destroy
    build_base_team!
  end

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

    apply_team_lines!(pricing, Array(suggestion["linhas"]))
    ensure_always_included_lines!(pricing)
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

    # Registra a busca no acervo quando há algo indexado (mesmo padrão de
    # fetch_ai_schedule_suggestion) — a IA pode ver como a Papyrus montou a equipe em projetos
    # parecidos antes de sugerir.
    def fetch_ai_team_suggestion
      conversation.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
      conversation.ask_internally(team_suggestion_prompt, hide_response: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    def team_suggestion_prompt
      describe = lambda do |professional|
        "- professional_id: #{professional.id} | #{professional.name} (#{professional.role}) | " \
        "habilitação: #{professional.specialties.presence || '—'}"
      end
      active = Professional.active.order(:name).to_a
      fixed, roster = active.partition(&:always_included)

      <<~TEXT
        Você monta a composição de equipe de uma proposta de consultoria ambiental da Papyrus,
        com base em tudo que já foi analisado nesta conversa (ET, TR quando houver, documentos
        complementares e propostas anteriores semelhantes, se houver). #{study_types_context}
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
          "Geoprocessamento e Cartografia", "Diagnóstico do Meio Físico", "Coordenação Geral").
        - Um mesmo profissional pode ter mais de uma linha se entregar frentes distintas.
        - Esforço em duas quantidades:
          #{EFFORT_UNITS_GUIDE}
          Estime pelo porte e complexidade do escopo. Se realmente não houver base, use 0 (o
          consultor ajusta na Tela de Precificação), mas ainda assim inclua a linha.

        Diga também se o ET ou o TR exige que a proposta técnica e a comercial sejam apresentadas
        como documentos/envelopes SEPARADOS (comum em licitação) — se nenhum falar nada, considere
        que NÃO (documento único).

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "linhas": [
            { "professional_id": 12, "deliverable_name": "Geoprocessamento e Cartografia", "man_hours": 40, "field_days": 2 }
          ],
          "documentos_separados": false,
          "justificativa_documentos_separados": "..."
        }
      TEXT
    end

    # Mesmo padrão do ProcessLegalNormsJob: registra a ferramenta ANTES de ask_internally (é essa
    # chamada que efetivamente a usa pela primeira vez — dali em diante Conversation#ask_internally
    # já registra sozinho, sempre que detectar histórico de uso de tool). Só quando há acervo
    # indexado, mesmo motivo de RespondToMessageJob: ferramenta que sempre volta vazia vira algo
    # que a IA acha que tentou.
    def fetch_ai_schedule_suggestion
      conversation.with_tool(SearchHistoricalArchiveTool.new) if HistoricalProposalChunk.embedded.exists?
      conversation.ask_internally(schedule_suggestion_prompt, hide_response: true)
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
      conversation.ask_internally(key_points_suggestion_prompt(items), hide_response: true)
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

    # Valida cada linha contra o cadastro (professional_id ativo e real; entregável não vazio) e
    # descarta duplicata (mesmo profissional + mesmo entregável). Linha de um profissional FIXO
    # reaproveita a linha-placeholder dele (papel como entregável, 0h — deixada por
    # build_base_team!) em vez de criar outra ao lado.
    def apply_team_lines!(pricing, lines)
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
        attrs = { deliverable_name: deliverable, man_hours: effort(line["man_hours"]), field_days: effort(line["field_days"]) }
        placeholder = professional.always_included && pricing.proposal_professionals
          .find_by(professional: professional, deliverable_name: professional.role, man_hours: 0, field_days: 0)

        if placeholder
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
