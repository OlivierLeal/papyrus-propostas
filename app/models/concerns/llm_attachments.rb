# Anexo do CHAT (Message/GeneralMessage) que o provider não aceita como está — .pptx, .msg, .zip,
# HEIC, foto grande, planilha… — não vai bruto (derrubaria o turno inteiro, ou a IA deduziria o
# conteúdo pelo nome). Passa pelo AttachmentPreparer: vira PDF/JPEG convertido, texto, ou um aviso
# explícito. Só o que é nativo (PDF/DOC/DOCX e imagem comum dentro do limite) segue pelo caminho
# normal do ruby_llm (#attachment_sources de cada model filtra com #llm_managed_attachment?).
#
# O que o consultor vê no chat não muda — o arquivo original continua baixável. Mesma regra dos
# outros anexos: só a mensagem mais recente manda o conteúdo (#stale_for_llm?), porque a leitura
# fica registrada na resposta da IA.
module LlmAttachments
  extend ActiveSupport::Concern

  private
    def extract_content
      content = super
      prepared = prepared_attachments_for_llm
      return content unless prepared

      base_text = content.is_a?(RubyLLM::Content) ? content.text : content
      merged = [ base_text, prepared.inline_text ].compact_blank.join("\n\n")
      sources = (content.is_a?(RubyLLM::Content) ? content.attachments : []) + prepared.attachments
      return merged if sources.empty?

      RubyLLM::Content.new(merged, sources)
    end

    def llm_managed_attachment?(attachment)
      !AttachmentPreparer.native?(attachment)
    end

    def prepared_attachments_for_llm
      return nil unless attachments.attached? && !stale_for_llm?

      @prepared_attachments_for_llm ||= begin
        managed = attachments.select { |attachment| attachment.blob.metadata["kind"] != "kmz" && llm_managed_attachment?(attachment) }
        AttachmentPreparer.new(managed).call if managed.any?
      end
    end
end
