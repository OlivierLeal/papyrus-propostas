# O consultor diz no chat que um arquivo enviado na conversa (complementar ou anexo do chat) é o TR
# do estudo. Vira o TR da proposta na hora — a decisão já é dele: Anexo I do .docx e ProcessTrJob.
class SetTermOfReferenceTool < RubyLLM::Tool
  description <<~DESC
    Marca um arquivo já enviado nesta conversa como o Termo de Referência (TR) do estudo. Use só
    quando o consultor disser que aquele arquivo é o TR. Ele passa a ir como Anexo I da proposta
    (texto editável) e é lido como TR (exigências, diagnósticos, condicionantes).
    Também aceita o TR que o SISTEMA encontrou (card "Usar como Anexo I" ainda sem decisão): quando o
    consultor pedir no chat pra incluir/anexar esse TR, chame com usar_encontrado: true.
  DESC

  param :arquivo, desc: "Nome (ou parte do nome) do arquivo. Vazio = o PDF/Word mais recente enviado na conversa.", required: false
  param :usar_encontrado, type: "boolean", required: false,
    desc: "true = aceitar o TR que o sistema encontrou e está esperando decisão no card (o consultor pediu pra incluir)."

  EXTENSIONS = %w[.pdf .docx .doc .odt .rtf].freeze

  def initialize(conversation:)
    super()
    @conversation = conversation
  end

  def execute(arquivo: nil, usar_encontrado: false)
    if @conversation.client_term_of_reference?
      return { aviso: "O cliente já enviou o TR na Tela de Setup — é ele que vai como Anexo I." }.to_json
    end
    return accept_found if ActiveModel::Type::Boolean.new.cast(usar_encontrado)

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

  # Charlene pediu "incluir o TR no anexo" na PTC26047 e o card do TR encontrado ficou pendente: a IA
  # não tinha como aceitar, e a revisão saiu dizendo que o TR estava no Anexo I sem estar.
  def accept_found
    candidate = @conversation.term_of_reference_candidates.where(status: "pending").order(:id).last
    return { error: "Não há TR encontrado esperando decisão nesta conversa." }.to_json unless candidate

    candidate.accept!(Current.user)
    { success: true, tr: candidate.title,
      status: "Aceito como TR do estudo: o sistema está baixando e lendo o arquivo; ele vai como Anexo I na próxima " \
              "geração do documento (se o download falhar, o card no chat avisa)." }.to_json
  end

  def find_attachment(name)
    files = @conversation.messages.where(role: "user", internal: false).order(:id)
      .flat_map { |message| message.attachments.to_a }
      .select { |attachment| EXTENSIONS.include?(File.extname(attachment.filename.to_s).downcase) }
    files = files.select { |a| I18n.transliterate(a.filename.to_s.downcase).include?(I18n.transliterate(name.to_s.downcase.strip)) } if name.present?
    files.last
  end
end
