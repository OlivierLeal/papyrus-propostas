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

    # `text` pode vir nil dentro de um Result presente (baixou o PDF, mas não deu pra ler nem com
    # OCR) — quem persiste (SearchLegalNormsTool) só guarda LegalNorm quando `text` está presente.
    Result = Data.define(:pdf_bytes, :content_type, :text, :ocr_used)

    def initialize(client: Client.new)
      @client = client
    end

    # anexo_id: Norma#anexo_id (o GUID em `NomeAnexo`). Devolve um Result (bytes do PDF + texto
    # extraído, com ou sem OCR) ou nil se o anexo não existir ou não baixar.
    def fetch(anexo_id)
      return nil if anexo_id.blank?

      bytes, content_type = @client.download("#{DOWNLOAD_PATH}?nome=#{ERB::Util.url_encode(anexo_id)}", referer: Normas::PAGE_URL)
      return nil if bytes.blank? || content_type.to_s.exclude?("pdf")

      extraction = extract_text(bytes)
      Result.new(pdf_bytes: bytes, content_type: content_type, text: extraction&.fetch(:text), ocr_used: extraction&.fetch(:ocr_used) || false)
    end

    # Mesmo contrato de sempre (String ou nil) — nil quando o anexo não existir, não baixar, ou
    # for um PDF ilegível mesmo com OCR (ver Rag::TextExtractor) — nunca inventa conteúdo quando
    # não consegue ler o documento de verdade.
    def texto(anexo_id)
      fetch(anexo_id)&.text
    end

    private

    # Ligado (ocr: true, 2026-09): quase toda norma tentada por texto completo na conversa 38
    # veio "não consegui ler" — a maioria do que o CAL guarda é PDF escaneado. Rag::Ocr já cacheia
    # por SHA256 do arquivo em disco (tmp/rag_ocr_cache), então reler a MESMA norma não paga o
    # custo do OCR de novo mesmo antes desta mudança persistir o resultado no banco.
    def extract_text(bytes)
      Tempfile.create([ "cal_norma", ".pdf" ], binmode: true) do |file|
        file.write(bytes)
        file.flush

        result = Rag::TextExtractor.new(file.path, ocr: true).call
        next nil unless result.ok?

        { text: result.plain_text.truncate(MAX_TEXT_CHARS), ocr_used: result.from_ocr? }
      end
    rescue StandardError => e
      Rails.logger.error("[Cal::Documento] falha ao extrair texto: #{e.class} #{e.message}")
      nil
    end
  end
end
