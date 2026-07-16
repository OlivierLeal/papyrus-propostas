class ConversationsController < ApplicationController
  before_action :set_conversation, only: %i[ show confirm remove_attachment ]
  before_action :set_study_types, only: %i[ new create ]

  def index
    @conversations = current_user.conversations.order(created_at: :desc)
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

    tr = params[:tr]
    kmz = params[:kmz]
    complementary_documents = Array(params[:complementary_documents]).reject(&:blank?)
    file_errors = validate_setup_files(tr, kmz)

    if file_errors.any?
      @conversation.errors.add(:base, file_errors.join(" "))
      render :new, status: :unprocessable_entity
      return
    end

    @conversation.save!
    message = @conversation.messages.build(role: "user", content: setup_message_content(tr, kmz, complementary_documents))
    attach_with_kind(message, tr, "tr") if tr.present?
    attach_with_kind(message, kmz, "kmz") if kmz.present?
    complementary_documents.each { |doc| attach_with_kind(message, doc, "complementary") }
    message.save!

    redirect_to @conversation, notice: "Arquivos enviados. Revise antes de confirmar."
  end

  def show
    @setup_message = @conversation.messages.order(:created_at).first
  end

  def confirm
    unless @conversation.status == "setup"
      redirect_to @conversation, alert: "Esta proposta já foi enviada para processamento."
      return
    end

    steps = Conversation::PROCESSING_STEPS.index_with do |step|
      @conversation.attachments_of_kind(step == "comp_docs" ? "complementary" : step).any? ? "pending" : "skipped"
    end.merge("summary" => "pending")

    @conversation.update!(status: "processing", setup_completed_at: Time.current, processing_steps: steps)

    ProcessTrJob.perform_later(@conversation.id) if steps["tr"] == "pending"
    ProcessCompDocsJob.perform_later(@conversation.id) if steps["comp_docs"] == "pending"
    @conversation.check_processing_complete!

    redirect_to @conversation, notice: "Proposta confirmada e enviada para processamento."
  end

  def remove_attachment
    unless @conversation.status == "setup"
      redirect_to @conversation, alert: "Não é possível remover arquivos após o envio para processamento."
      return
    end

    attachment = ActiveStorage::Attachment
      .joins("INNER JOIN messages ON messages.id = active_storage_attachments.record_id")
      .where(record_type: "Message", messages: { conversation_id: @conversation.id })
      .find(params[:attachment_id])
    attachment.purge

    redirect_to @conversation, notice: "Arquivo removido."
  end

  private
    def set_conversation
      @conversation = current_user.conversations.find(params[:id])
    end

    def set_study_types
      @study_types = StudyType.order(:name)
    end

    def conversation_params
      params.require(:conversation).permit(:client_name, :study_type_id)
    end

    def validate_setup_files(tr, kmz)
      errors = []
      errors << "TR deve ser um arquivo PDF ou DOCX." if tr.present? && !tr_content_type?(tr)
      errors << "KMZ deve ser um arquivo .kmz ou .kml." if kmz.present? && !kmz_filename?(kmz)
      errors
    end

    def tr_content_type?(file)
      %w[
        application/pdf
        application/msword
        application/vnd.openxmlformats-officedocument.wordprocessingml.document
      ].include?(file.content_type)
    end

    def kmz_filename?(file)
      file.original_filename.match?(/\.(kmz|kml)\z/i)
    end

    def setup_message_content(tr, kmz, complementary_documents)
      parts = []
      parts << "TR: #{tr.original_filename}" if tr.present?
      parts << "KMZ: #{kmz.original_filename}" if kmz.present?
      parts << "#{complementary_documents.size} documento(s) complementar(es)" if complementary_documents.any?

      return "Proposta criada sem arquivos anexados." if parts.empty?

      "Arquivos enviados para análise — #{parts.join(', ')}."
    end
end
