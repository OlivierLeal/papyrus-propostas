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
  param :produtos, type: "array", desc: "Lista dos produtos/entregáveis a serem entregues (ex.: \"EIA - Estudo de Impacto Ambiental\")"
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
      technical_filename = @proposal.docx_filename("tecnica")
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
      technical_filename = @proposal.docx_filename("tecnica")
      commercial_filename = @proposal.docx_filename("comercial")
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
      combined_filename = @proposal.docx_filename("combined")
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
        "ESCOPO_METODOLOGIA" => args[:escopo_e_metodologia],
        "PRAZO_EXECUCAO" => args[:prazo_de_execucao],
        "EQUIPE_LIDER_PROJETO_NOME" => lider[0],
        "EQUIPE_LIDER_PROJETO_QUALIFICACAO" => lider[1],
        "EQUIPE_SEG_TRABALHO_NOME" => seguranca[0],
        "EQUIPE_SEG_TRABALHO_QUALIFICACAO" => seguranca[1]
      }.tap { |placeholders| placeholders["MAPA_AREA_ESTUDO"] = "" if images.empty? }
    end

    def build_tables(args, description)
      produtos = Array(args[:produtos]).map { |nome| [ nome, "1", "Digital (PDF)" ] }

      {
        0 => { rows: @proposal.docx_revision_rows(current_description: description) },
        1 => { rows: produtos },
        3 => { rows: @proposal.docx_price_rows, auto_number: true },
        4 => { rows: @proposal.docx_payment_schedule_rows, auto_number: true }
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
