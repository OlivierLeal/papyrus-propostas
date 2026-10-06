# O consultor aceitou o TR do card (TermOfReferenceCandidate#accept!): busca o arquivo — o PDF da
# norma no CAL ou o link da internet — e o torna o TR da proposta. O ProcessTrJob lê ele em seguida
# (achados do TR), igual leria o TR enviado no setup.
class AcceptTermOfReferenceJob < ApplicationJob
  queue_as :default

  def perform(candidate_id)
    candidate = TermOfReferenceCandidate.find(candidate_id)
    return unless candidate.accepting?

    attach_file!(candidate) unless candidate.file.attached?
    candidate.update!(status: "accepted", error: nil)
    ProcessTrJob.perform_later(candidate.conversation_id)
  rescue TermOfReferenceAnnex::Downloader::Error, ArgumentError => e
    fail!(candidate, e.message)
  rescue StandardError => e
    Rails.logger.error("AcceptTermOfReferenceJob falhou para #{candidate_id}: #{e.class} #{e.message}")
    fail!(candidate, "Não consegui buscar o arquivo agora.")
  ensure
    candidate&.conversation&.broadcast_refresh
  end

  private

  def attach_file!(candidate)
    case candidate.source
    when "cal"
      SearchLegalNormsTool.new.full_text(candidate.norm_code) # guarda a norma (texto + PDF) se ainda não estiver
      norm = LegalNorm.find_by(codigo: candidate.norm_code)
      raise ArgumentError, "Não consegui baixar o documento da norma no CAL." unless norm&.pdf&.attached?

      candidate.file.attach(norm.pdf.blob)
    when "internet"
      download = TermOfReferenceAnnex::Downloader.call(candidate.url)
      candidate.file.attach(io: download.io, filename: download.filename, content_type: download.content_type)
    else
      raise ArgumentError, "Arquivo do TR não encontrado."
    end
  end

  def fail!(candidate, message)
    candidate&.update!(status: "failed", error: message)
  end
end
