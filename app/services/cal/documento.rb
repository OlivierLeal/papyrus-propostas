module Cal
  # Baixa e extrai o texto do PDF anexo de uma norma legal — a busca (Cal::Normas) só devolve
  # metadados e um resumo curto (`Assunto`); quando a IA precisa saber o que a norma exige de
  # verdade, é aqui que o texto completo do documento entra.
  #
  # Endpoint descoberto lendo o JS carregado pela própria página autenticada do CAL (bundle
  # uploadConfiguracoes), não documentado: `GET /UploadArquivo/ObterPdfPorNome?nome=<anexo_id>`
  # redireciona (302) pra uma URL assinada num CDN à parte (files.sistemacal.com.br, com
  # Expires/Signature próprios — ver Cal::Client#download).
  class Documento
    DOWNLOAD_PATH = "/UploadArquivo/ObterPdfPorNome".freeze

    # Teto generoso (uma norma extensa passa fácil de 50 mil caracteres), mas existe pra um PDF
    # anômalo não estourar sozinho o contexto de quem usa o texto depois — mesmo raciocínio do
    # AttachmentPreparer::MAX_TEXT_CHARS.
    MAX_TEXT_CHARS = 200_000

    def initialize(client: Client.new)
      @client = client
    end

    # anexo_id: Norma#anexo_id (o GUID em `NomeAnexo`). Devolve o texto extraído, ou nil se o
    # anexo não existir, não baixar, ou for um PDF escaneado sem OCR (ver Rag::TextExtractor) —
    # nunca inventa conteúdo quando não consegue ler o documento de verdade.
    def texto(anexo_id)
      return nil if anexo_id.blank?

      bytes, content_type = @client.download("#{DOWNLOAD_PATH}?nome=#{ERB::Util.url_encode(anexo_id)}", referer: Normas::PAGE_URL)
      return nil if bytes.blank? || content_type.to_s.exclude?("pdf")

      extract_text(bytes)
    end

    private

    def extract_text(bytes)
      Tempfile.create([ "cal_norma", ".pdf" ], binmode: true) do |file|
        file.write(bytes)
        file.flush

        result = Rag::TextExtractor.new(file.path, ocr: false).call
        result.ok? ? result.plain_text.truncate(MAX_TEXT_CHARS) : nil
      end
    rescue StandardError => e
      Rails.logger.error("[Cal::Documento] falha ao extrair texto: #{e.class} #{e.message}")
      nil
    end
  end
end
