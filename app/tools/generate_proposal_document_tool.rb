# Ferramenta que a IA chama quando o consultor pede pra gerar a Proposta Técnica e/ou Comercial.
# Só o TEXTO (prosa) vem da IA — preço, equipe, formato do documento (único ou separado) vêm
# direto do banco (ProjectPricing/ProposalProfessional), nunca da IA. Ver CLAUDE.md seção 8/9.
#
# A proposta técnica pode ser gerada antes da precificação estar aprovada (proposal.status ==
# "draft") — a equipe/horas sugeridas pela IA na criação da proposta já bastam pro texto técnico,
# que não mostra valores. A comercial (ou o documento combinado) exige status "priced"/"approved"
# (Tela de Precificação confirmada pelo consultor), porque mostra números que ainda não foram
# revisados. Ver #execute.
#
# Recebe `conversation:`, não `proposal:` — a Proposal pode nem existir ainda (o consultor nunca
# clicou em "Avançar para Precificação"). Achado na prática: exigir isso antes de QUALQUER geração,
# inclusive só-técnica, deixava o fluxo sem sentido pro consultor ("não quero avançar pra preço,
# quero só a técnica"). Agora #execute cria a proposta sozinha (Conversation#ensure_proposal!) na
# primeira vez que a ferramenta é chamada de verdade — o botão continua existindo pra quem prefere
# ir direto pra Tela de Precificação, mas deixou de ser pré-requisito pra gerar a técnica pelo chat.
class GenerateProposalDocumentTool < RubyLLM::Tool
  description <<~DESC
    Gera o(s) arquivo(s) .docx da proposta preenchidos, usando o texto que você escrever pra
    cada seção (baseado no ET, no TR quando houver, nos documentos complementares e em propostas anteriores
    semelhantes já analisados nesta conversa) e os dados de preço/equipe que já existem no
    sistema. Enquanto a proposta ainda está em "draft" (preço não aprovado na Tela de
    Precificação), esta ferramenta só gera a proposta_tecnica.docx — sem tabela de preço nem
    cronograma de desembolso, que ainda não foram revisados pelo consultor; a comercial (ou o
    documento combinado) só fica disponível depois que o status virar "priced"/"approved". Só
    chame depois de confirmar que não falta nenhuma informação que bloqueia a proposta (ver
    passo a passo interno). Nomes/CNPJ que você não tiver certeza, escreva "A confirmar" em vez
    de inventar.
  DESC

  param :nome_cliente, desc: "Razão social do cliente/contratante"
  param :contato_cliente, desc: "Nome da pessoa de contato no cliente, ou \"A confirmar\" se não souber"
  param :descricao_servico, desc: "Descrição curta do serviço (ex.: \"elaboração de EIA/RIMA do Parque Eólico X\")"
  param :municipios, desc: "Município(s) do empreendimento"
  param :estado, desc: "Sigla do estado (ex.: BA)"
  param :cnpj_cliente, desc: "CNPJ do cliente, ou \"A confirmar\" se não souber"
  param :objetivo_dos_servicos, desc: "Texto da seção 'Objetivo dos Serviços'"
  param :caracterizacao_do_empreendimento, desc: "Texto da seção 'Caracterização do Empreendimento'"
  param :nome_documento_tr, desc: "Nome do documento de ET (Pedido Técnico do Estudo) usado como base do escopo — " \
    "o nome do parâmetro ficou de antes da separação ET/TR, mas o valor esperado é o do ET, o documento principal"
  param :escopo_e_metodologia, desc: "Parágrafo(s) INTRODUTÓRIOS da seção 'Escopo e Metodologia' — contexto geral de " \
    "como o serviço será executado, antes de entrar nos tópicos (ver topicos_escopo). Se o escopo for simples " \
    "demais pra render nenhum tópico à parte, pode ser o texto inteiro da seção."
  param :topicos_escopo, type: "array", required: false,
    desc: "Etapas do PROCESSO de execução do serviço — não é um resumo do que será diagnosticado (isso já está em " \
          "caracterizacao_do_empreendimento/objetivo_dos_servicos), é como a Papyrus vai EXECUTAR: reuniões, " \
          "vistorias, tramitação junto ao órgão, cada estudo/produto intermediário que compõe o serviço. Pense " \
          "nas etapas reais do trabalho, na ordem em que acontecem, por exemplo (adapte ao que o ET/TR e a " \
          "equipe/precificação desta proposta realmente preveem — nem toda proposta tem todas): " \
          "enquadramento/classificação legal do empreendimento; reunião de kick-off (quantos profissionais); " \
          "assessoria para tramitação do processo junto ao órgão (protocolo, acompanhamento, quantas vistorias " \
          "técnicas, quantas reuniões com o órgão); o(s) diagnóstico(s)/estudo(s) em si (pode dividir por meio " \
          "físico/biótico/socioeconômico aqui dentro, se fizer sentido); cada produto intermediário que tiver " \
          "etapa própria (ex.: estudos arqueológicos com suas fichas/relatórios específicos, inventário florestal, " \
          "reunião pública, planos e programas ambientais); geoprocessamento/cartografia, quando for entrega " \
          "própria. Cada item no formato \"Título | Texto da etapa\" (ex.: \"Reunião Kick Off | Será realizada 01 " \
          "reunião de abertura do contrato, com participação de 02 profissionais...\"). Números de vistorias, " \
          "reuniões, dias e campanhas de campo têm que vir do que já está definido nesta proposta ([ESTADO ATUAL " \
          "DA PROPOSTA]/achados do ET-TR) — nunca invente quantidade; se não souber, descreva a atividade sem " \
          "quantificar. O sistema numera cada item como subtópico da seção (5.1, 5.2...) e destaca o título em " \
          "negrito — não escreva o número nem \"5.\" você mesma, nem tente negritar com texto. Use o " \
          "search_historical_archive pra ver como a Papyrus estruturou o escopo de projetos parecidos antes de " \
          "escrever — a estrutura processual varia bastante por tipo de estudo e vale seguir o padrão já usado."
  param :prazo_de_execucao, desc: "Prazo contratual, por extenso (ex.: \"120 dias corridos\")"
  param :produtos, type: "array",
    desc: "Lista dos produtos/entregáveis — tem que bater com o que topicos_escopo descreve: cada etapa que gera " \
          "um documento próprio (o estudo/diagnóstico principal, mas também fichas, relatórios e certidões " \
          "intermediárias de cada produto específico do escopo — ex.: um estudo arqueológico costuma gerar FCA, " \
          "PAIPA e RAIPA como produtos separados, não só \"Estudos Arqueológicos\"; inventário florestal, planos " \
          "e programas ambientais, relatório de reunião pública e certidão/certificado da licença também são " \
          "produtos próprios quando essas etapas existirem no escopo). Não invente produto que não tenha etapa " \
          "correspondente no escopo. Cada item pode trazer o formato depois de uma barra vertical " \
          "(ex.: \"Estudo Ambiental para Atividades de Médio Impacto (EMI) | Word e PDF\"); sem a barra, " \
          "o sistema usa \"Digital (PDF)\". Um item terminado em dois-pontos e sem formato vira uma linha de " \
          "AGRUPAMENTO no quadro (ex.: \"Licença Prévia (LP):\") — use isso para separar os produtos por fase " \
          "do licenciamento quando a proposta tiver mais de uma fase, como a Papyrus faz."

  param :itens_nao_previstos, type: "array", required: false,
    desc: "O que esta proposta NÃO cobre, um item por linha (ex.: \"Execução dos planos e programas ambientais\", " \
          "\"Regularização fundiária\", \"Tratativas junto a INCRA ou FUNAI\"). Toda proposta da Papyrus fecha o " \
          "escopo com essa lista — é o que impede o cliente de cobrar depois um serviço que não foi orçado. " \
          "Liste o que for específico deste projeto; a frase padrão sobre proposta complementar o sistema " \
          "acrescenta sozinho."
  param :nome_arquivo,
    desc: "SÓ quando o consultor disser como o arquivo deve se chamar (ex.: \"o arquivo tem que se chamar " \
          "PTC26002_PMM_LU_Simões Filho_BA\"). Copie o nome exatamente como ele escreveu, sem inventar, sem " \
          "completar e sem a extensão .docx — o sistema cuida da revisão (_Rev.NN) e de distinguir técnica de " \
          "comercial. Se ele não falou nada sobre nome de arquivo, NÃO envie este parâmetro: o sistema usa o " \
          "padrão da Papyrus. Envie \"padrão\" se ele pedir para voltar ao nome automático.",
    required: false

  param :descricao_revisao, desc: "Resumo curto do que mudou desde a última geração (ex.: \"Ajuste de escopo conforme pedido do consultor\"). " \
    "Ignorado na 1ª geração da proposta — o sistema sempre usa \"Emissão Inicial\" nesse caso — mas o parâmetro deve ser enviado mesmo assim."

  param :obrigacoes_contratante_adicionais, type: "array", required: false,
    desc: "Obrigações EXTRAS da CONTRATANTE (o cliente) além das já fixas no modelo (acesso à área, fornecer " \
          "documentos, pagar taxas do órgão, etc. — não repita essas). Um item por linha, só o que o ET ou o TR " \
          "exigir especificamente deste cliente (ex.: \"Fornecer escolta armada para as vistorias de campo\", " \
          "\"Disponibilizar embarcação para acesso à área insular\"). Não invente — só o que estiver escrito no " \
          "documento. Se nada exigir algo além do padrão, não envie este parâmetro."

  param :obrigacoes_papyrus_adicionais, type: "array", required: false,
    desc: "Obrigações EXTRAS da PAPYRUS (CONTRATADA) além das já fixas no modelo (executar o escopo, usar pessoal " \
          "qualificado, seguir a legislação, etc. — não repita essas). Um item por linha, só o que o ET ou o TR " \
          "exigir especificamente (ex.: \"Emitir relatório mensal de acompanhamento ao órgão financiador\", " \
          "\"Realizar treinamento da equipe do cliente em SST antes do início dos serviços\"). Não invente — só o " \
          "que estiver escrito no documento. Se nada exigir algo além do padrão, não envie este parâmetro."

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(**args)
    @proposal = @conversation.proposal || @conversation.ensure_proposal!
    return { error: blocked_reason }.to_json if @proposal.nil?

    apply_filename_override!(args[:nome_arquivo])
    @proposal.increment!(:version)
    description = @proposal.version == 1 ? "Emissão Inicial" : args[:descricao_revisao].to_s.presence || "Revisão solicitada pelo consultor"

    filler = ProposalDocxFiller.new(Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx"))
    images = build_images
    schedules = build_schedules
    placeholders = build_placeholders(args, images)
    tables = build_tables(args, description)
    remove_paragraph_if_blank = OBRIGACOES_ADICIONAIS_TOKENS

    # Em draft (preço ainda não aprovado na Tela de Precificação), só a parte técnica pode sair —
    # a comercial mostra valores que ainda não foram revisados/aprovados pelo consultor. A equipe
    # sugerida pela IA já existe nesse ponto (Proposal#build_with_ai_suggested_team!), então o
    # texto técnico (que cita líder/segurança do trabalho) já tem o que precisa. O cronograma
    # (seção 9, sempre técnica) sai igual em qualquer status — não é dado de preço.
    if @proposal.status == "draft"
      technical_filename = @proposal.docx_filename("tecnica", municipio: args[:municipios], estado: args[:estado])
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("tecnica") }
      )
      attach!(files[:technical], technical_filename, "tecnica", description)
      { success: true, version: @proposal.version, filenames: [ technical_filename ],
        message: "Gerado o arquivo #{technical_filename} — só a parte técnica, sem " \
          "valores. A proposta comercial fica disponível depois que o preço for revisado e aprovado na Tela de " \
          "Precificação." }.to_json
    elsif @proposal.document_split == "separated"
      technical_filename = @proposal.docx_filename("tecnica", municipio: args[:municipios], estado: args[:estado])
      commercial_filename = @proposal.docx_filename("comercial", municipio: args[:municipios], estado: args[:estado])
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("tecnica") },
        commercial_overrides: { "TITULO_LINHA2" => "COMERCIAL", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("comercial") }
      )
      attach!(files[:technical], technical_filename, "tecnica", description)
      attach!(files[:commercial], commercial_filename, "comercial", description)
      { success: true, version: @proposal.version, filenames: [ technical_filename, commercial_filename ],
        message: "Gerados 2 arquivos: #{technical_filename} e #{commercial_filename} (versão #{@proposal.version}), disponíveis na Tela de Precificação." }.to_json
    else
      combined_filename = @proposal.docx_filename("combined", municipio: args[:municipios], estado: args[:estado])
      bytes = filler.fill(placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank)
      attach!(bytes, combined_filename, "combined", description)
      { success: true, version: @proposal.version, filenames: [ combined_filename ],
        message: "Gerado o arquivo #{combined_filename}, disponível na Tela de Precificação." }.to_json
    end
  rescue StandardError => e
    Rails.logger.error("GenerateProposalDocumentTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui gerar o documento agora. Tente novamente em instantes." }.to_json
  end

  private
    # A mensagem antiga ("falta o tipo de estudo ser identificado (ET ainda em processamento) ou a
    # revisão ser concluída") juntava duas causas diferentes e apontava pra uma terceira que
    # normalmente já não é verdade. Na conversa 31 (produção) o ET estava "done" havia 15 minutos e
    # o que faltava era cadastro de tipo de estudo — a IA leu "ET ainda em processamento", concluiu
    # que era falha do backend, repetiu a chamada quatro vezes e mandou o consultor procurar o time
    # de desenvolvimento. Cada causa agora diz o que ela é e onde se resolve.
    def blocked_reason
      if @conversation.study_type.blank?
        cadastrados = StudyType.order(:name).pluck(:name).join(", ").presence || "nenhum tipo cadastrado"
        "Não dá pra criar a proposta: o TIPO DE ESTUDO desta conversa não está definido no sistema " \
        "(sem ele não existe menu de horas, logo não existe equipe nem proposta). Isso não se " \
        "resolve tentando de novo — NÃO repita esta chamada. Peça ao consultor que escolha o tipo " \
        "de estudo no painel \"Tipo de estudo\", na coluna à esquerda da tela da proposta, e clique " \
        "em Salvar; se nenhum servir, ele cadastra o que falta em Configurações > Tipos de Estudo. " \
        "Tipos cadastrados hoje: #{cadastrados}."
      else
        "Não dá pra criar a proposta agora: os documentos ainda estão sendo processados " \
        "(situação atual: #{@conversation.status_label}). Avise o consultor e tente de novo quando " \
        "o processamento terminar."
      end
    end

    # Item de lista opcional no modelo (7.1/7.2 — ver ProposalDocxFiller#fill_simple_placeholders!)
    # — some o parágrafo inteiro em vez de deixar um "●" sem texto quando não há nada extra.
    OBRIGACOES_ADICIONAIS_TOKENS = %w[OBRIGACOES_CONTRATANTE_ADICIONAIS OBRIGACOES_PAPYRUS_ADICIONAIS].freeze

    # O consultor às vezes dita o nome do arquivo no chat ("tem que se chamar PTC26002_PMM..."),
    # normalmente porque a pasta na rede e o controle de propostas já foram criados com aquele
    # nome (itens 1 e 2 do passo a passo interno). A partir daí é esse o nome, inclusive nas
    # versões seguintes — por isso fica gravado na proposta, e não só nesta geração.
    RESET_WORDS = %w[padrao padrão default automatico automático].freeze

    def apply_filename_override!(nome)
      nome = nome.to_s.strip
      return if nome.blank?

      @proposal.update!(docx_filename_override: RESET_WORDS.include?(nome.downcase) ? nil : nome)
    end

    # Só o mapa real da Mapbox (PNG) entra no .docx — o croqui SVG de reserva (quando a Mapbox
    # não está disponível) não tem como virar imagem embutida do Word sem conversão, então nesse
    # caso o placeholder cai no fluxo de texto normal e sai em branco (ver build_placeholders).
    def build_images
      area_image = @proposal.conversation.geospatial_result&.area_image
      return {} unless area_image&.attached? && area_image.content_type == "image/png"

      { "MAPA_AREA_ESTUDO" => area_image.download }
    end

    # Cronograma (ver ScheduleItem/ScheduleTableBuilder/ProposalDocxFiller#insert_schedule_
    # tables!) — já mora no banco desde a criação da proposta (Proposal#build_with_ai_suggested_
    # schedule!) e é ajustável na Tela de Precificação, então não é a IA quem manda isso pro
    # gerador, é lido direto daqui, igual equipe e desembolso. Um tipo sem data de início setada
    # (ou sem nenhum item) fica de fora silenciosamente — a página só existe quando os dois estão
    # presentes.
    def build_schedules
      pricing = @proposal.project_pricing
      return {} unless pricing

      {
        "servico" => schedule_payload(pricing, "servico", pricing.schedule_papyrus_start_date),
        "implantacao" => schedule_payload(pricing, "implantacao", pricing.schedule_empreendimento_start_date)
      }.compact
    end

    def schedule_payload(pricing, type, start_date)
      items = pricing.schedule_items.select { |item| item.schedule_type == type }
      return nil if items.empty? || start_date.blank?

      { start_date: start_date, items: items }
    end

    def build_placeholders(args, images)
      lider = @proposal.team_slot_for_docx
      seguranca = @proposal.team_slot_for_docx(role_hint: "segurança")

      {
        "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("combined"),
        "REVISAO_ATUAL" => format("%02d", @proposal.version - 1),
        "TITULO_LINHA2" => "TÉCNICA E",
        "TITULO_LINHA3" => "COMERCIAL",
        "DATA_EMISSAO_INICIAL" => Date.current.strftime("%d/%m/%Y"),
        "NOME_CLIENTE" => args[:nome_cliente],
        "CONTATO_CLIENTE" => args[:contato_cliente],
        "DESCRICAO_SERVICO" => args[:descricao_servico],
        "MUNICIPIOS" => args[:municipios],
        "ESTADO" => args[:estado],
        "CNPJ_CLIENTE" => args[:cnpj_cliente],
        "NOME_CLIENTE_ASSINATURA" => args[:nome_cliente],
        "OBJETIVO_SERVICOS" => args[:objetivo_dos_servicos],
        "CARACTERIZACAO_EMPREENDIMENTO" => args[:caracterizacao_do_empreendimento],
        "NOME_DOCUMENTO_TR" => args[:nome_documento_tr],
        "ESCOPO_METODOLOGIA" => escopo_com_itens_nao_previstos(args),
        "PRAZO_EXECUCAO" => args[:prazo_de_execucao],
        "EQUIPE_LIDER_PROJETO_NOME" => lider[0],
        "EQUIPE_LIDER_PROJETO_QUALIFICACAO" => lider[1],
        "EQUIPE_SEG_TRABALHO_NOME" => seguranca[0],
        "EQUIPE_SEG_TRABALHO_QUALIFICACAO" => seguranca[1],
        "PRECO_TOTAL" => @proposal.docx_total_price,
        "OBRIGACOES_CONTRATANTE_ADICIONAIS" => join_lines(args[:obrigacoes_contratante_adicionais]),
        "OBRIGACOES_PAPYRUS_ADICIONAIS" => join_lines(args[:obrigacoes_papyrus_adicionais])
      }.tap { |placeholders| placeholders["MAPA_AREA_ESTUDO"] = "" if images.empty? }
    end

    # Cada item vira um parágrafo/item de lista próprio no modelo (ver expand_into_paragraphs!);
    # lista vazia devolve "" — junto com remove_paragraph_if_blank, isso some o item de lista
    # inteiro, em vez de deixar um "●" sem texto na maioria das propostas (que não tem nada extra).
    def join_lines(items)
      Array(items).map { |item| item.to_s.strip }.compact_blank.join("\n")
    end

    # Os índices são a POSIÇÃO da tabela no modelo, não um id: 0 = sumário de revisões,
    # 1 = produtos, 2 = equipe técnica (preenchida por placeholder, não por linha), 3 = desembolso.
    # Mudaram na revisão de 2026-08 do modelo, quando o quadro de preço por linha deixou de existir.
    # Frase de fechamento fixa: é a proteção comercial da Papyrus e aparece em toda proposta
    # validada por eles. Não fica a cargo da IA lembrar dela.
    RESSALVA_PROPOSTA_COMPLEMENTAR =
      "Caso sejam solicitados serviços e estudos não contemplados nesta proposta, estes serão objeto de " \
      "proposta complementar.".freeze

    # O escopo escrito pela IA sempre termina com o que a proposta NÃO cobre. Vem como parâmetro
    # próprio (e não embutido na prosa) porque era justamente o que sumia: nas propostas geradas
    # até aqui essa lista simplesmente não existia, enquanto as escritas por gente sempre a têm.
    # A seção "ESCOPO E METODOLOGIA DE EXECUÇÃO DO SERVIÇO" é sempre a 5ª de nível 1 no modelo —
    # a estrutura de seções é fixa, só o conteúdo varia por proposta — por isso o número dos
    # subtópicos pode ser calculado aqui: a IA não tem como saber a posição real da seção no
    # documento renderizado, só o sistema sabe.
    SECAO_ESCOPO_NUMERO = 5

    def escopo_com_itens_nao_previstos(args)
      itens = Array(args[:itens_nao_previstos]).map { |item| item.to_s.strip }.compact_blank
      bloco = [ "**Itens não previstos**" ]
      bloco.concat(itens.map { |item| "- #{item}" })
      bloco << RESSALVA_PROPOSTA_COMPLEMENTAR

      [ args[:escopo_e_metodologia], topicos_do_escopo(args), bloco.join("\n\n") ].compact_blank.join("\n\n")
    end

    # "Título | texto" vira "**5.N TÍTULO**" (negrito — ver ProposalDocxFiller#apply_line!)
    # seguido do texto normal do tópico. Devolve "" quando a IA não usar topicos_escopo (escopo
    # sem divisão temática), então não sobra nada em branco entre a introdução e os itens não
    # previstos.
    def topicos_do_escopo(args)
      topicos = Array(args[:topicos_escopo]).filter_map do |item|
        titulo, texto = item.to_s.split("|", 2).map(&:strip)
        titulo.presence && texto.presence && [ titulo, texto ]
      end

      topicos.each_with_index.map do |(titulo, texto), index|
        "**#{SECAO_ESCOPO_NUMERO}.#{index + 1} #{titulo.upcase}**\n\n#{texto}"
      end.join("\n\n")
    end

    # "Produto | Formato" vira linha normal; "Fase:" (sem formato) vira linha de agrupamento, do
    # jeito que a Papyrus separa os produtos por fase do licenciamento.
    def build_tables(args, description)
      produtos = Array(args[:produtos]).filter_map do |item|
        nome, formato = item.to_s.split("|", 2).map(&:strip)
        next if nome.blank?

        agrupamento = formato.blank? && nome.end_with?(":")
        [ nome, agrupamento ? "" : formato.presence || "Digital (PDF)" ]
      end

      {
        0 => { rows: @proposal.docx_revision_rows(current_description: description) },
        1 => { rows: produtos },
        3 => { rows: @proposal.docx_payment_schedule_rows, auto_number: true }
      }
    end

    # broadcast_refresh na mão: anexar um blob em generated_documents não passa pelos callbacks de
    # Conversation (broadcasts_refreshes só reage a create/update/destroy da própria Conversation),
    # então sem isso o card "Documentos" da barra lateral só atualizava com F5 — achado na prática.
    def attach!(bytes, filename, kind, description)
      @proposal.generated_documents.attach(
        io: StringIO.new(bytes),
        filename: filename,
        content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        metadata: { kind: kind, version: @proposal.version, description: description }
      )
      @conversation.broadcast_refresh
    end
end
