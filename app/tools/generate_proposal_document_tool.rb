# Ferramenta que a IA chama quando o consultor pede pra gerar a Proposta Técnica e Comercial.
# Só o TEXTO (prosa) vem da IA — preço, equipe, formato do documento (único ou separado) vêm
# direto do banco (ProjectPricing/ProposalProfessional), nunca da IA. Ver CLAUDE.md seção 8/9.
class GenerateProposalDocumentTool < RubyLLM::Tool
  description <<~DESC
    Gera o arquivo .docx da Proposta Técnica e Comercial preenchido, usando o texto que você
    escrever pra cada seção (baseado no TR, nos documentos complementares e em propostas
    anteriores semelhantes já analisados nesta conversa) e os dados de preço/equipe que já
    existem no sistema. Só chame depois de confirmar que não falta nenhuma informação que
    bloqueia a proposta (ver passo a passo interno). Nomes/CNPJ que você não tiver certeza,
    escreva "A confirmar" em vez de inventar.
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

  def initialize(proposal:)
    super()
    @proposal = proposal
  end

  def execute(**args)
    return { error: "A precificação ainda não está completa — não é possível gerar o documento agora." }.to_json unless @proposal.status.in?(%w[priced approved])

    @proposal.increment!(:version)
    description = @proposal.version == 1 ? "Emissão Inicial" : args[:descricao_revisao].to_s.presence || "Revisão solicitada pelo consultor"

    filler = ProposalDocxFiller.new(Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx"))
    images = build_images
    placeholders = build_placeholders(args, images)
    tables = build_tables(args, description)

    if @proposal.document_split == "separated"
      files = filler.fill_split(
        placeholders: placeholders, tables: tables, images: images,
        technical_overrides: { "TITULO_LINHA2" => "TÉCNICA", "TITULO_LINHA3" => "" },
        commercial_overrides: { "TITULO_LINHA2" => "COMERCIAL", "TITULO_LINHA3" => "" }
      )
      attach!(files[:technical], "proposta_tecnica.docx", "tecnica", description)
      attach!(files[:commercial], "proposta_comercial.docx", "comercial", description)
      { success: true, version: @proposal.version, filenames: %w[proposta_tecnica.docx proposta_comercial.docx],
        message: "Gerados 2 arquivos: proposta_tecnica.docx e proposta_comercial.docx (versão #{@proposal.version}), disponíveis na Tela de Precificação." }.to_json
    else
      bytes = filler.fill(placeholders: placeholders, tables: tables, images: images)
      attach!(bytes, "proposta_tecnica_comercial.docx", "combined", description)
      { success: true, version: @proposal.version, filenames: %w[proposta_tecnica_comercial.docx],
        message: "Gerado o arquivo proposta_tecnica_comercial.docx (versão #{@proposal.version}), disponível na Tela de Precificação." }.to_json
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
        "NUMERO_PROPOSTA" => @proposal.docx_numero_proposta,
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

    def attach!(bytes, filename, kind, description)
      @proposal.generated_documents.attach(
        io: StringIO.new(bytes),
        filename: filename,
        content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        metadata: { kind: kind, version: @proposal.version, description: description }
      )
    end
end
