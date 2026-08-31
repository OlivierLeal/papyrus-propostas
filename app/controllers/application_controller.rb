class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private
    # Anexa um arquivo enviado por upload a uma mensagem, marcando o "tipo"
    # (et/tr/kmz/complementary) nos metadados do blob — é assim que os jobs de processamento
    # identificam qual anexo é qual.
    def attach_with_kind(message, file, kind)
      message.attachments.attach(
        io: file,
        filename: file.original_filename,
        content_type: file.content_type,
        metadata: { kind: kind }
      )
    end
end
