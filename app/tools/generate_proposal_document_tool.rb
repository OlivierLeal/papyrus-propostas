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
    cada seção (baseado no TR, nos documentos complementares e em propostas anteriores
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
  param :nome_documento_tr, desc: "Nome do documento de TR usado como base do escopo"
  param :escopo_e_metodologia, desc: "Texto da seção 'Escopo e Metodologia', descrevendo como o serviço será executado"
  param :prazo_de_execucao, desc: "Prazo contratual, por extenso (ex.: \"120 dias corridos\")"
  param :produtos, type: "array",
    desc: "Lista dos produtos/entregáveis. Cada item pode trazer o formato depois de uma barra vertical " \
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

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(**args)
    @proposal = @conversation.proposal || @conversation.ensure_proposal!
    return { error: "Ainda não dá pra criar a proposta — falta o tipo de estudo ser identificado " \
      "(TR ainda em processamento) ou a revisão ser concluída." }.to_json if @proposal.nil?

    apply_filename_override!(args[:nome_arquivo])
    @proposal.increment!(:version)
    description = @proposal.version == 1 ? "Emissão Inicial" : args[:descricao_revisao].to_s.presence || "Revisão solicitada pelo consultor"

    filler = ProposalDocxFiller.new(Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx"))
    images = build_images
    placeholders = build_placeholders(args, images)
    tables = build_tables(args, description)

    # Em draft (preço ainda não aprovado na Tela de Precificação), só a parte técnica pode sair —
    # a comercial mostra valores que ainda não foram revisados/aprovados pelo consultor. A equipe
    # sugerida pela IA já existe nesse ponto (Proposal#build_with_ai_suggested_team!), então o
    # texto técnico (que cita líder/segurança do trabalho) já tem o que precisa.
    if @proposal.status == "draft"
      technical_filename = @proposal.docx_filename("tecnica", municipio: args[:municipios], estado: args[:estado])
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images,
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
        placeholders: placeholders, tables: tables, images: images,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("tecnica") },
        commercial_overrides: { "TITULO_LINHA2" => "COMERCIAL", "TITULO_LINHA3" => "", "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta("comercial") }
      )
      attach!(files[:technical], technical_filename, "tecnica", description)
      attach!(files[:commercial], commercial_filename, "comercial", description)
      { success: true, version: @proposal.version, filenames: [ technical_filename, commercial_filename ],
        message: "Gerados 2 arquivos: #{technical_filename} e #{commercial_filename} (versão #{@proposal.version}), disponíveis na Tela de Precificação." }.to_json
    else
      combined_filename = @proposal.docx_filename("combined", municipio: args[:municipios], estado: args[:estado])
      bytes = filler.fill(placeholders: placeholders, tables: tables, images: images)
      attach!(bytes, combined_filename, "combined", description)
      { success: true, version: @proposal.version, filenames: [ combined_filename ],
        message: "Gerado o arquivo #{combined_filename}, disponível na Tela de Precificação." }.to_json
    end
  rescue StandardError => e
    Rails.logger.error("GenerateProposalDocumentTool falhou para proposal #{@proposal.id}: #{e.class} #{e.message}")
    { error: "Não consegui gerar o documento agora. Tente novamente em instantes." }.to_json
  end

  private
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
        "PRECO_TOTAL" => @proposal.docx_total_price
      }.tap { |placeholders| placeholders["MAPA_AREA_ESTUDO"] = "" if images.empty? }
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
    def escopo_com_itens_nao_previstos(args)
      itens = Array(args[:itens_nao_previstos]).map { |item| item.to_s.strip }.compact_blank
      bloco = [ "Itens não previstos" ]
      bloco.concat(itens.map { |item| "- #{item}" })
      bloco << RESSALVA_PROPOSTA_COMPLEMENTAR

      [ args[:escopo_e_metodologia], bloco.join("\n\n") ].compact_blank.join("\n\n")
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
