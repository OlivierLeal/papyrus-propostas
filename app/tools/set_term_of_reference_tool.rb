# O consultor diz no chat que um arquivo enviado na conversa (complementar ou anexo do chat) é o TR
# do estudo. Vira o TR da proposta na hora — a decisão já é dele: Anexo I do .docx e ProcessTrJob.
class SetTermOfReferenceTool < RubyLLM::Tool
  description <<~DESC
    Marca um arquivo já enviado nesta conversa como o Termo de Referência (TR) do estudo. Use só
    quando o consultor disser que aquele arquivo é o TR. Ele passa a ir como Anexo I da proposta
    (texto editável) e é lido como TR (exigências, diagnósticos, condicionantes).
  DESC

  param :arquivo, desc: "Nome (ou parte do nome) do arquivo. Vazio = o PDF/Word mais recente enviado na conversa.", required: false

  EXTENSIONS = %w[.pdf .docx .doc .odt .rtf].freeze

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(arquivo: nil)
    if @conversation.client_term_of_reference?
      return { aviso: "O cliente já enviou o TR na Tela de Setup — é ele que vai como Anexo I." }.to_json
    end

    attachment = find_attachment(arquivo)
    return { error: "Não encontrei PDF/Word enviado nesta conversa#{" com o nome \"#{arquivo}\"" if arquivo.present?}." }.to_json unless attachment

    candidate = @conversation.term_of_reference_candidates.create!(source: "consultor", title: attachment.filename.to_s, status: "accepting")
    candidate.file.attach(attachment.blob)
    AcceptTermOfReferenceJob.perform_later(candidate.id)
    candidate.announce!
    { success: true, arquivo: attachment.filename.to_s,
      status: "Marcado como TR do estudo: vai como Anexo I na próxima geração do documento, e o sistema está lendo as exigências dele." }.to_json
  end

  private

  def find_attachment(name)
    files = @conversation.messages.where(role: "user", internal: false).order(:id)
      .flat_map { |message| message.attachments.to_a }
      .select { |attachment| EXTENSIONS.include?(File.extname(attachment.filename.to_s).downcase) }
    files = files.select { |a| I18n.transliterate(a.filename.to_s.downcase).include?(I18n.transliterate(name.to_s.downcase.strip)) } if name.present?
    files.last
  end
end
