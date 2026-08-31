class ConversationsController < ApplicationController
  before_action :set_conversation, only: %i[ show update ]

  def index
    @conversations = Conversation.includes(:user, :study_type, :proposal).order(created_at: :desc)
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

  # Único jeito de definir/corrigir o tipo de estudo depois da criação — nunca no setup (ver
  # ProcessEtJob#assign_study_type!, que já preenche isso sozinho lendo o ET).
  def update
    @conversation.update!(study_type_params)
    redirect_to @conversation, notice: "Tipo de estudo atualizado."
  end

  private
    # Dispara automaticamente ao criar a proposta — não existe mais uma etapa manual de
    # "confirmar antes de processar" (ver CLAUDE.md, decisão revista).
    def start_processing!
      steps = Conversation::PROCESSING_STEPS.index_with do |step|
        @conversation.attachments_of_kind(step == "comp_docs" ? "complementary" : step).any? ? "pending" : "skipped"
      end.merge("summary" => "pending")

      @conversation.update!(status: "processing", setup_completed_at: Time.current, processing_steps: steps)

      ProcessEtJob.perform_later(@conversation.id) if steps["et"] == "pending"
      ProcessTrJob.perform_later(@conversation.id) if steps["tr"] == "pending"
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
      params.require(:conversation).permit(:study_type_id)
    end

    def validate_setup_files(ets, trs, kmz)
      errors = []
      errors << "ET deve ser um arquivo PDF ou DOCX." if ets.any? { |et| !document_content_type?(et) }
      errors << "TR deve ser um arquivo PDF ou DOCX." if trs.any? { |tr| !document_content_type?(tr) }
      errors << "KMZ deve ser um arquivo .kmz ou .kml." if kmz.present? && !kmz_filename?(kmz)
      errors
    end

    def document_content_type?(file)
      %w[
        application/pdf
        application/msword
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
      ].include?(file.content_type)
    end

    def kmz_filename?(file)
      file.original_filename.match?(/\.(kmz|kml)\z/i)
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
