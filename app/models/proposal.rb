class Proposal < ApplicationRecord
  belongs_to :conversation
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
  SCHEDULE_FILENAME_LABELS = { "servico" => "Cronograma_Servico", "implantacao" => "Cronograma_Implantacao" }.freeze

  def schedule_filename(type)
    base = docx_filename("tecnica").sub(/\.docx\z/, "")
    "#{base}_#{SCHEDULE_FILENAME_LABELS.fetch(type)}.xml"
  end

  # Nome/qualificação da Equipe Técnica no DOCX vêm de dados reais do sistema (proposal_
  # professionals + professionals.registration), nunca da IA — ela não deve inventar nome ou
  # registro profissional de alguém. "Líder do projeto" = quem tem mais horas de escritório
  # (normalmente quem coordena); "Segurança do trabalho" = quem tiver esse termo no cargo, se
  # existir alguém assim na equipe desta proposta (em branco se não houver).
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

  # Linhas do Quadro de Desembolso — marco e % do preço total, direto do payment_schedule. Só a
  # porcentagem (2026-09, a pedido do consultor — o quadro deixou de trazer R$/DATA por parcela;
  # essas datas continuam editáveis na Tela de Precificação, só não vão mais impressas aqui).
  def docx_payment_schedule_rows
    project_pricing.payment_schedule.map do |item|
      [ item["label"], format_percentage(item["percentage"]) ]
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

  # Pede pra IA sugerir horas por profissional/entregável com base em tudo que já foi
  # extraído do ET, do TR (quando houver) e dos documentos complementares desta conversa
  # (CLAUDE.md seção 5).
  # A sugestão é restrita ao "menu" de profissionais/entregáveis do study_templates —
  # a IA nunca pode inventar um profissional ou entregável que não exista no sistema.
  # Se a IA falhar ou não sugerir nada válido, cai no template padrão como segurança.
  def build_with_ai_suggested_team!
    templates = conversation.study_type.study_templates.includes(:professional).to_a
    pricing = create_project_pricing!

    if templates.empty?
      # Sem menu de horas cadastrado pro tipo de estudo (só eia_rima tem hoje), a IA mapeia o
      # time a partir do CADASTRO COMPLETO de profissionais (cargo + especialidades) contra o
      # escopo desta conversa — pedido da Papyrus, "cadastrar um template por tipo de estudo é
      # difícil". Continua restrito a professional_id real e ativo (a IA nunca inventa gente);
      # como não há menu de entregável aqui, é a IA quem nomeia o entregável de cada linha.
      # Falha/resposta vazia cai no rescue -> build_from_template! (só Diretoria/Coordenação),
      # exatamente o que já saía antes desta mudança.
      suggestion = fetch_ai_roster_suggestion
      apply_roster_lines!(pricing, Array(suggestion["linhas"]))
      ensure_always_included_lines!(pricing, templates)
      update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")
      return finalize!(pricing)
    end

    suggestion = fetch_ai_suggestion(templates)
    apply_lines!(pricing, Array(suggestion["linhas"]), templates)
    apply_lines!(pricing, template_fallback_lines(templates), templates) if pricing.proposal_professionals.none?
    ensure_always_included_lines!(pricing, templates)
    update!(document_split: suggestion["documentos_separados"] ? "separated" : "combined")

    finalize!(pricing)
  rescue StandardError => e
    Rails.logger.error("build_with_ai_suggested_team! falhou para conversation #{conversation_id}: #{e.class} #{e.message}")
    project_pricing&.destroy
    build_from_template!
  end

  # Copia o template padrão direto, sem envolver a IA — usado como fallback de segurança.
  def build_from_template!
    templates = conversation.study_type.study_templates.includes(:professional).to_a
    pricing = create_project_pricing!
    apply_lines!(pricing, template_fallback_lines(templates), templates)
    ensure_always_included_lines!(pricing, templates)
    finalize!(pricing)
  end

  # Sugere fases/atividades do cronograma a partir do que já foi extraído do ET/TR nesta
  # conversa (CLAUDE.md seção 8). Diferente da equipe técnica, não existe "menu" de fases por
  # tipo de estudo — é conteúdo livre, então não passa por catálogo/apply_lines!, só parse +
  # persistência direta. Chamado depois de build_with_ai_suggested_team!/build_from_template!
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

    # "40" quando o percentual for inteiro, "37,5" (vírgula, padrão PT-BR) quando não — nunca o
    # "%" no texto da célula, a coluna já se chama "% DO ITEM".
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

    def fetch_ai_suggestion(templates)
      conversation.ask_internally(suggestion_prompt(templates), hide_response: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    def suggestion_prompt(templates)
      menu = templates.map do |t|
        "- professional_id: #{t.professional_id} | #{t.professional.name} (#{t.professional.role}) | " \
        "entregável: \"#{t.deliverable_name}\" | padrão: #{t.hours_office_default}h escritório, #{t.hours_field_default}h campo"
      end.join("\n")

      <<~TEXT
        Você é um assistente que sugere a composição de equipe para uma proposta de consultoria
        ambiental, com base em tudo que já foi analisado nesta conversa (ET, TR quando houver, e
        documentos complementares, incluindo propostas anteriores semelhantes, se houver).

        Profissionais e entregáveis DISPONÍVEIS para o tipo de estudo "#{conversation.study_type.name}"
        (não sugira nada fora desta lista — nunca invente professional_id ou entregável novo):
        #{menu}

        Para CADA item da lista acima, sugira as horas necessárias para este projeto específico,
        considerando a complexidade, os diagnósticos exigidos e as demais informações já extraídas
        nesta conversa. Se um item não for necessário para este projeto, sugira 0 para ambas as horas.

        Além disso, releia o ET e o TR (quando houver) e diga se algum deles exige que a proposta
        técnica e a proposta comercial sejam apresentadas como documentos/envelopes SEPARADOS
        (comum em licitação pública) — se nenhum falar nada sobre isso, considere que NÃO exige
        (documento único).

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "linhas": [
            { "professional_id": 12, "deliverable_name": "Coordenação geral", "hours_office": 30, "hours_field": 0 }
          ],
          "documentos_separados": false,
          "justificativa_documentos_separados": "..."
        }
      TEXT
    end

    def fetch_ai_roster_suggestion
      conversation.ask_internally(roster_suggestion_prompt, hide_response: true)
      response = conversation.messages.where(role: "assistant").order(:created_at).last
      AiJsonResponse.parse(response.content) || {}
    end

    # Usado quando o tipo de estudo NÃO tem study_templates: o "menu" passa a ser o cadastro
    # inteiro de profissionais (menos os always_included, que o sistema junta sozinho depois).
    # A IA escolhe QUEM e o QUE cada um faz nesta proposta a partir do cargo/especialidades;
    # o nome do entregável é livre (não há catálogo de entregável por tipo de estudo).
    def roster_suggestion_prompt
      menu = Professional.active.where(always_included: false).order(:name).map do |professional|
        "- professional_id: #{professional.id} | #{professional.name} (#{professional.role}) | " \
        "especialidades: #{professional.specialties.presence || '—'}"
      end.join("\n")

      <<~TEXT
        Você é um assistente que monta a composição de equipe para uma proposta de consultoria
        ambiental, com base em tudo que já foi analisado nesta conversa (ET, TR quando houver,
        documentos complementares e propostas anteriores semelhantes, se houver).

        Este tipo de estudo ("#{conversation.study_type.name}") não tem um modelo de equipe
        pré-cadastrado, então o menu abaixo é o QUADRO COMPLETO de profissionais da Papyrus. Para
        cada necessidade real deste projeto (diagnósticos exigidos, geoprocessamento/cartografia,
        estudos temáticos, análise jurídica, arqueologia, etc.), escolha o profissional cujo
        cargo/especialidades melhor atendem e diga o que ele entrega nesta proposta.

        Profissionais disponíveis (não invente professional_id — use só os desta lista; a
        Diretoria e a Coordenação são adicionadas automaticamente pelo sistema, não precisa
        incluí-las):
        #{menu}

        Regras:
        - Só inclua um profissional se o escopo desta proposta realmente exigir a atuação dele.
        - "deliverable_name" é o entregável/frente de trabalho dele NESTA proposta (ex.:
          "Geoprocessamento e Cartografia", "Diagnóstico do Meio Físico", "Análise Jurídica").
        - Sugira as horas de escritório e de campo necessárias para este projeto. Se não tiver
          base para estimar, use 0 nos dois campos (o consultor ajusta na Tela de Precificação),
          mas ainda assim inclua a linha.
        - Um mesmo profissional pode ter mais de uma linha se entregar frentes distintas.

        Diga também se o ET ou o TR exige que a proposta técnica e a comercial sejam apresentadas
        como documentos/envelopes SEPARADOS (comum em licitação) — se nenhum falar nada, considere
        que NÃO (documento único).

        Responda APENAS com um JSON válido (sem markdown, sem texto antes ou depois), exatamente
        neste formato:

        {
          "linhas": [
            { "professional_id": 12, "deliverable_name": "Geoprocessamento e Cartografia", "hours_office": 40, "hours_field": 0 }
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

    # Versão sem catálogo de entregável (tipo de estudo sem study_templates): valida só que o
    # professional_id é de um profissional ativo e real; o deliverable_name é o que a IA nomeou.
    def apply_roster_lines!(pricing, lines)
      valid = Professional.active.where(always_included: false).index_by(&:id)

      lines.each do |line|
        professional = valid[line["professional_id"].to_i]
        deliverable = line["deliverable_name"].to_s.strip
        next flag_out_of_catalog(line, reason: :roster) if professional.nil? || deliverable.blank?

        hours_office = line["hours_office"].to_f
        hours_field = line["hours_field"].to_f

        pricing.proposal_professionals.create!(
          professional: professional, deliverable_name: deliverable,
          hours_office: hours_office, hours_field: hours_field
        )
      end
    end

    def apply_lines!(pricing, lines, templates)
      valid_templates = templates.index_by { |t| [ t.professional_id, t.deliverable_name.to_s.strip.downcase ] }

      lines.each do |line|
        key = [ line["professional_id"].to_i, line["deliverable_name"].to_s.strip.downcase ]
        template = valid_templates[key]
        # A regra determinística continua: linha fora do cadastro NÃO entra na precificação. O que
        # mudou é que ela para de sumir em silêncio — a IA ter sugerido um profissional ou
        # entregável que não existe é informação para o consultor (ou falta cadastro, ou a IA
        # inventou), não um detalhe de implementação.
        next flag_out_of_catalog(line) unless template

        hours_office = line["hours_office"].to_f
        hours_field = line["hours_field"].to_f
        next if hours_office.zero? && hours_field.zero?

        pricing.proposal_professionals.create!(
          professional: template.professional,
          deliverable_name: template.deliverable_name,
          hours_office: hours_office,
          hours_field: hours_field
        )
      end
    end

    # Profissionais fixos (professionals.always_included — Diretoria/Coordenação da Papyrus)
    # entram em TODA proposta, com as horas padrão do template como ponto de partida. apply_lines!
    # pula linha com 0h nos dois campos (ver acima) e a IA pode simplesmente não sugerir a linha
    # — nenhum dos dois casos pode fazer um fixo sumir da equipe, então a garantia é do sistema,
    # não da sugestão da IA. O consultor ainda ajusta as horas depois, na Tela de Precificação.
    #
    # NÃO itera só sobre `templates`: um study_type sem NENHUM study_template cadastrado (RAP,
    # Relatório Técnico, PEA, EMI, hoje — ver CLAUDE.md seção 11.1) tem `templates` vazio, e antes
    # disso fazia o fixo sumir também nesses casos — achado comparando uma proposta EMI gerada
    # pelo sistema com a PTC real aprovada pela Papyrus (nem Charlene/Ricardo apareciam). Por isso
    # a fonte da verdade aqui é `Professional.always_included`, com o "role" como deliverable_name
    # quando não há template pro study_type dessa proposta pra saber o nome do entregável.
    def ensure_always_included_lines!(pricing, templates)
      present = pricing.proposal_professionals.pluck(:professional_id, :deliverable_name).to_set
      templates_by_professional = templates.group_by(&:professional_id)

      Professional.active.always_included.find_each do |professional|
        professional_templates = templates_by_professional[professional.id]

        if professional_templates.present?
          professional_templates.each do |template|
            next if present.include?([ template.professional_id, template.deliverable_name ])

            pricing.proposal_professionals.create!(
              professional: template.professional,
              deliverable_name: template.deliverable_name,
              hours_office: template.hours_office_default,
              hours_field: template.hours_field_default
            )
          end
        else
          deliverable_name = professional.role
          next if present.include?([ professional.id, deliverable_name ])

          pricing.proposal_professionals.create!(
            professional: professional, deliverable_name: deliverable_name, hours_office: 0, hours_field: 0
          )
        end
      end
    end

    def flag_out_of_catalog(line, reason: :template)
      professional = Professional.find_by(id: line["professional_id"])
      descricao = [ professional&.name || "profissional ##{line['professional_id']}",
                    line["deliverable_name"].presence ].compact_blank.join(" — ")
      motivo = reason == :roster ?
        "A IA sugeriu este profissional para a equipe, mas o professional_id não existe ou está inativo no cadastro. Não entrou na precificação." :
        "A IA sugeriu esta linha para a equipe, mas ela não existe nos modelos de horas cadastrados para o tipo de estudo. Não entrou na precificação."

      conversation.project_findings.create!(
        field: "outro", nature: "sugestao", source_kind: "sistema",
        value: "sugestão de equipe fora do cadastro: #{descricao}",
        excerpt: motivo
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[Proposal] não consegui registrar sugestão fora do cadastro: #{e.message}")
    end

    def template_fallback_lines(templates)
      templates.map do |t|
        {
          "professional_id" => t.professional_id,
          "deliverable_name" => t.deliverable_name,
          "hours_office" => t.hours_office_default,
          "hours_field" => t.hours_field_default
        }
      end
    end
end
