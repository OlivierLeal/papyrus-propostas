# Leva para o acervo do RAG a proposta que o consultor APROVOU (CLAUDE.md seção 11.1).
#
# Só depois da aprovação: nesse ponto o documento passou por revisão humana e é equivalente ao
# que já está no acervo em disco. Indexar todo rascunho encheria o índice de versões que o
# consultor descartou minutos depois — e o RAG passaria a ensinar a IA a repetir o que foi
# rejeitado.
#
# O registro fica com origin "sistema", nunca "acervo": daqui a um ano precisa continuar sendo
# possível distinguir uma proposta histórica assinada de uma que este sistema produziu.
class IndexApprovedProposalJob < ApplicationJob
  queue_as :default

  def perform(proposal_id)
    proposal = Proposal.find(proposal_id)
    return unless proposal.status == "approved"

    document = latest_generated_document(proposal)
    return Rails.logger.info("[IndexApprovedProposalJob] proposta #{proposal_id} sem documento gerado") unless document

    text = extract_text(document)
    return Rails.logger.warn("[IndexApprovedProposalJob] não extraiu texto de #{document.filename}") if text.blank?

    index!(proposal, document, text)
  rescue StandardError => e
    # Indexar é um ganho posterior, não parte da entrega: falhar aqui não pode afetar a
    # aprovação que o consultor acabou de fazer.
    Rails.logger.error("IndexApprovedProposalJob failed for proposal #{proposal_id}: #{e.class} #{e.message}")
  end

  private

  # A técnica e a comercial saem como arquivos separados quando o ET/TR exige; a técnica é a que
  # tem a prosa que interessa ao RAG (a comercial é tabela de preço, que nunca é referência).
  def latest_generated_document(proposal)
    documents = proposal.generated_documents.map(&:blob)
    return nil if documents.empty?

    newest_version = documents.filter_map { |blob| blob.metadata["version"] }.max
    candidates = documents.select { |blob| blob.metadata["version"] == newest_version }.presence || documents

    candidates.find { |blob| blob.filename.to_s.match?(/tecnica/i) } || candidates.first
  end

  def extract_text(blob)
    Tempfile.create([ "proposta", File.extname(blob.filename.to_s) ]) do |file|
      file.binmode
      blob.download { |chunk| file.write(chunk) }
      file.flush

      result = Rag::TextExtractor.new(file.path).call
      result.ok? ? result.text : nil
    end
  end

  def index!(proposal, document, text)
    conversation = proposal.conversation
    checksum = document.checksum

    record = HistoricalProposal.find_or_initialize_by(source_sha256: "blob:#{checksum}")
    record.assign_attributes(
      origin: "sistema",
      conversation: conversation,
      job_name: proposal.docx_numero_proposta,
      job_number: proposal.docx_numero_proposta,
      client_name: conversation.client_name,
      subject: conversation.study_type&.name,
      source_path: "active_storage:#{document.key}",
      relative_path: document.filename.to_s,
      filename: document.filename.to_s,
      chunker_version: Rag::Indexer::PIPELINE_VERSION,
      role: "proposta_papyrus",
      role_source: "sistema",
      status: "ok",
      revision: proposal.version,
      year: Date.current.year,
      superseded: false
    )

    # Salvar+chunkar+embedar é compartilhado com HistoricalProposal#approve! (ver Rag::
    # ProposalIndexer) — os dois caminhos convergem aqui, só o gatilho e os atributos acima mudam.
    Rag::ProposalIndexer.new(record, text).call!
  end
end
