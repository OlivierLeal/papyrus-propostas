class ConversationsController < ApplicationController
  include Pagy::Method

  before_action :set_conversation, only: %i[ show update confirm_framing ]

  # Múltiplo de 1, 2 e 3 (colunas da grade no celular/tablet/desktop): a página nunca termina com
  # uma linha pela metade no meio de um ano.
  PER_PAGE = 24

  # Scroll infinito: a 1ª página vem com a tela; as seguintes chegam pelo turbo-frame lazy que fica
  # no fim da lista (conversations/_page), quando ele entra na tela.
  def index
    @query = params[:q]
    conversations = Conversation.search(@query)
    @pagy, @conversations = pagy(conversations, limit: PER_PAGE)
    @group_counts = group_counts(conversations)
    @ai_costs = Conversation.ai_costs_usd(@conversations)
    # O título do ano só aparece quando o ano muda — numa página que continua o ano da anterior,
    # a grade segue sem título repetido.
    @previous_group = helpers.year_group_label(conversations.offset(@pagy.offset - 1).pick(:created_at)) if @pagy.offset.positive?

    render :page, layout: false if turbo_frame_request?
  end

  def new
    @conversation = Conversation.new
  end

  def create
    @conversation = current_user.conversations.new(conversation_params)

    if @conversation.invalid?
      render :new, status: :unprocessable_entity
      return
    end

    ets = Array(params[:et]).reject(&:blank?)
    trs = Array(params[:tr]).reject(&:blank?)
    kmz = params[:kmz]
    complementary_documents = Array(params[:complementary_documents]).reject(&:blank?)
    file_errors = validate_setup_files(ets, trs, kmz)

    if file_errors.any?
      @conversation.errors.add(:base, file_errors.join(" "))
      render :new, status: :unprocessable_entity
      return
    end

    @conversation.save!
    @conversation.apply_system_instructions!
    message = @conversation.messages.build(role: "user", content: setup_message_content(ets, trs, kmz, complementary_documents, params[:notes]))
    ets.each { |et| attach_with_kind(message, et, "et") }
    trs.each { |tr| attach_with_kind(message, tr, "tr") }
    attach_with_kind(message, kmz, "kmz") if kmz.present?
    complementary_documents.each { |doc| attach_with_kind(message, doc, "complementary") }
    message.save!

    start_processing!

    redirect_to @conversation, notice: "Proposta criada e enviada para processamento."
  end

  def show
  end

  # Único jeito de definir/corrigir os tipos de estudo depois da criação — nunca no setup (ver
  # Conversation#assign_study_types_from_findings!, que já preenche isso sozinho lendo o ET/TR).
  # Pode ser N tipos, ou nenhum (proposta de acompanhamento) — ver CLAUDE.md seção 13.
  def update
    @conversation.update!(study_type_params)
    redirect_to @conversation, notice: "Tipo de estudo atualizado."
  end

  def confirm_framing
    if @conversation.confirm_framing!(Current.session.user)
      redirect_to @conversation, notice: "Enquadramento confirmado."
    else
      redirect_to @conversation, alert: "Decida antes a divergência entre a legislação e o pedido do cliente (card no chat)."
    end
  end

  private
    # Quantas propostas em cada grupo (ano atual, anterior, "Anteriores") na lista INTEIRA, não só
    # na página carregada — o badge do título do grupo não pode mudar conforme o scroll. O ano é
    # extraído no fuso da aplicação, o mesmo de `created_at.year` no Ruby (virada do ano).
    def group_counts(conversations)
      zone = Conversation.connection.quote(Time.zone.tzinfo.identifier)
      year = Arel.sql("EXTRACT(YEAR FROM conversations.created_at AT TIME ZONE 'UTC' AT TIME ZONE #{zone})::int")
      conversations.except(:includes, :order).group(year).count.each_with_object(Hash.new(0)) do |(value, count), counts|
        counts[helpers.year_group_label_for(value)] += count
      end
    end

    # Dispara automaticamente ao criar a proposta — não existe mais uma etapa manual de
    # "confirmar antes de processar" (ver CLAUDE.md, decisão revista).
    def start_processing!
      steps = Conversation::PROCESSING_STEPS.index_with do |step|
        # "cal" não tem anexo — só faz sentido tentar se o ET vai rodar (é ele que identifica o
        # município) e o CAL estiver configurado; a decisão fina (achou município ou não) só o
        # ProcessEtJob sabe depois de rodar, ver #advance_after_et!.
        next(@conversation.attachments_of_kind("et").any? && Cal::Client.configured? ? "pending" : "skipped") if step == "cal"

        @conversation.attachments_of_kind(step == "comp_docs" ? "complementary" : step).any? ? "pending" : "skipped"
      end.merge("summary" => "pending")

      @conversation.update!(status: "processing", setup_completed_at: Time.current, processing_steps: steps)

      ProcessEtJob.perform_later(@conversation.id) if steps["et"] == "pending"
      # TR espera ET terminar (e a pesquisa no CAL entre os dois, quando ela roda) — ver
      # ProcessEtJob#advance_after_et! e ProcessLegalNormsJob. Só dispara direto daqui quando os
      # dois já nascem "skipped" (sem ET pra ler, não há o que esperar).
      ProcessTrJob.perform_later(@conversation.id) if steps["et"] == "skipped" && steps["cal"] == "skipped" && steps["tr"] == "pending"
      ProcessCompDocsJob.perform_later(@conversation.id) if steps["comp_docs"] == "pending"
      ProcessKmzJob.perform_later(@conversation.id) if steps["kmz"] == "pending"
      @conversation.check_processing_complete!
    end
    def set_conversation
      @conversation = Conversation.find(params[:id])
    end

    def conversation_params
      params.require(:conversation).permit(:client_name)
    end

    def study_type_params
      params.require(:conversation).permit(study_type_ids: [])
    end

    def validate_setup_files(ets, trs, kmz)
      errors = []
      errors << "ET deve ser um documento (PDF, Word, PowerPoint, e-mail, imagem ou planilha)." if ets.any? { |et| !readable_document?(et) }
      errors << "TR deve ser um documento (PDF, Word, PowerPoint, e-mail, imagem ou planilha)." if trs.any? { |tr| !readable_document?(tr) }
      errors << "A área de estudo deve ser KMZ, KML, GeoJSON, GeoPackage ou shapefile (.zip)." if kmz.present? && !kmz_filename?(kmz)
      errors
    end

    # ET/TR podem chegar em qualquer formato que o AttachmentPreparer transforma em algo que a IA
    # lê (2026-09-27): PDF/Word, PowerPoint/ODT/RTF (vira PDF), e-mail do cliente (.eml/.msg),
    # imagem escaneada, planilha, texto e .zip. Recusa só o que nunca vira conteúdo (CAD,
    # áudio/vídeo, formato desconhecido) e geometria (que tem campo próprio).
    READABLE_CATEGORIES = %i[document office email image spreadsheet text archive].freeze

    def readable_document?(file)
      READABLE_CATEGORIES.include?(AttachmentPreparer.category(file.original_filename))
    end

    def setup_message_content(ets, trs, kmz, complementary_documents, notes)
      parts = []
      parts << "ET: #{ets.map(&:original_filename).join(', ')}" if ets.any?
      parts << "TR: #{trs.map(&:original_filename).join(', ')}" if trs.any?
      parts << "KMZ: #{kmz.original_filename}" if kmz.present?
      parts << "#{complementary_documents.size} documento(s) complementar(es)" if complementary_documents.any?

      content = parts.any? ? "Arquivos enviados para análise — #{parts.join(', ')}." : "Proposta criada sem arquivos anexados."
      content += "\n\nObservações do consultor: #{notes.to_s.strip}" if notes.present?
      content
    end
end
