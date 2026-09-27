# Prepara os anexos de uma conversa para irem à IA. Único ponto por onde passa QUALQUER arquivo
# enviado pelo consultor antes de chegar ao provider — ET/TR/complementares (jobs) e anexos do
# chat (concern LlmAttachments em Message/GeneralMessage).
#
# O provider (Bedrock via ruby_llm) só aceita como anexo PDF/DOC/DOCX, texto e imagem
# PNG/JPEG/WEBP/GIF, com teto de tamanho. Qualquer outra coisa, sem este preparo, ou derrubava a
# chamada inteira (UnsupportedAttachmentError: .pptx, .msg, .zip…), ou era recusada lá (HEIC,
# TIFF), ou — pior — sumia e a IA DEDUZIA o conteúdo pelo nome do arquivo (visto num .pptx real
# de 21 MB: "indica múltiplos tipos de licenças…" sem nunca ter lido a apresentação).
#
# Cada anexo cai numa categoria:
#   nativo      — PDF/DOC/DOCX e imagem comum dentro do limite: vai como está.
#   documento   — acima do limite: texto extraído (com OCR se for PDF escaneado).
#   escritório  — PPTX/PPT/ODP/ODT/RTF…: LibreOffice → PDF, e o PDF segue como documento.
#   imagem      — HEIC/TIFF/BMP ou foto grande: ImageMagick → JPEG reduzido.
#   planilha    — XLSX/XLS/ODS/CSV: texto aba a aba.
#   texto       — TXT/MD/HTML/JSON/XML: lido e colado no prompt.
#   e-mail      — EML/MSG: cabeçalho + corpo em texto, e os anexos do e-mail preparados também.
#   zip         — descompactado; cada arquivo de dentro é preparado (com limite).
#   geo         — shapefile/GeoJSON/KML…: aviso — é o módulo geoespacial que processa, não a IA.
#   o resto     — CAD, áudio, vídeo, RAR/7z, desconhecido: aviso explícito, nunca silêncio.
class AttachmentPreparer
  # Margem sobre os 4,5 MB do provider: o arquivo é transportado em base64, que infla o
  # payload, e o limite reportado não deixa claro qual dos dois tamanhos ele mede.
  MAX_DOCUMENT_BYTES = 3.5.megabytes
  MAX_IMAGE_BYTES = 3.5.megabytes

  # Teto do texto extraído de UM arquivo. Um TR de 100 páginas dá ~200 mil caracteres e cabe
  # bem; o corte existe só para um anexo anômalo não estourar a janela de contexto sozinho.
  MAX_TEXT_CHARS = 400_000

  # ZIP/e-mail: quantos arquivos de dentro analisar, e até que profundidade (zip dentro de
  # e-mail dentro de zip…). Um zip com 300 fotos não pode virar 300 anexos numa chamada só.
  MAX_INNER_FILES = 20
  MAX_INNER_BYTES = 150.megabytes
  MAX_DEPTH = 2
  # Assinatura de e-mail, logo, ícone: imagem pequena dentro de e-mail não é conteúdo.
  MIN_EMAIL_IMAGE_BYTES = 15.kilobytes

  CATEGORIES = {
    document: %w[.pdf .docx .doc],
    image: %w[.jpg .jpeg .jfif .png .webp .gif .heic .heif .tif .tiff .bmp .avif],
    office: %w[.pptx .ppt .pps .ppsx .pptm .odp .odt .odg .rtf .docm .dotx .wpd .pages .key],
    spreadsheet: Rag::TextExtractor::SPREADSHEET_EXTENSIONS,
    text: %w[.txt .md .markdown .html .htm .json .xml .log],
    email: %w[.eml .msg],
    archive: %w[.zip],
    geo: %w[.kml .kmz .shp .shx .dbf .prj .cpg .sbn .sbx .qmd .geojson .gpkg .gml .gpx],
    cad: %w[.dwg .dxf .dgn .rvt .skp],
    media: %w[.mp3 .m4a .wav .ogg .opus .aac .mp4 .mov .avi .mkv .wmv .3gp .webm],
    other_archive: %w[.rar .7z .tar .gz .tgz .bz2]
  }.freeze
  NATIVE_IMAGES = %w[.jpg .jpeg .png .webp .gif].freeze

  Result = Data.define(:attachments, :inline_text, :converted) do
    def converted? = converted.any?
  end

  def self.category(filename)
    extension = File.extname(filename.to_s).downcase
    CATEGORIES.find { |_category, extensions| extensions.include?(extension) }&.first || :unknown
  end

  # Vai pro provider exatamente como está, sem conversão — o resto passa por este preparo.
  def self.native?(attachment)
    extension = File.extname(attachment.filename.to_s).downcase
    case category(attachment.filename)
    when :document then attachment.byte_size <= MAX_DOCUMENT_BYTES
    when :image then NATIVE_IMAGES.include?(extension) && attachment.byte_size <= MAX_IMAGE_BYTES
    else false
    end
  end

  def self.spreadsheet?(attachment)
    category(attachment.filename) == :spreadsheet
  end

  def initialize(attachments)
    @attachments = Array(attachments)
  end

  def call
    @sources = []
    @sections = []
    converted = []

    @attachments.each do |attachment|
      if self.class.native?(attachment)
        @sources << attachment
      else
        converted << attachment.filename.to_s
        prepare_attachment(attachment)
      end
    end

    Result.new(attachments: @sources, inline_text: @sections.presence&.join("\n\n"), converted: converted)
  end

  private

  def prepare_attachment(attachment)
    path = AttachmentConversions.materialize(attachment)
    prepare_file(path, attachment.filename.to_s, depth: 0)
  rescue StandardError => e
    Rails.logger.error("[AttachmentPreparer] falha ao preparar #{attachment.filename}: #{e.class} #{e.message}")
    @sections << notice(attachment.filename, "o sistema não conseguiu abrir o arquivo")
  end

  def prepare_file(path, filename, depth:)
    case self.class.category(filename)
    when :document then prepare_document(path, filename)
    when :image then prepare_image(path, filename)
    when :office then prepare_office(path, filename)
    when :spreadsheet then add_text(filename, extract_text(path), "planilha convertida em texto: cada aba começa com \"## Planilha: <nome>\" e cada linha tem as células separadas por \" | \"")
    when :text then add_text(filename, read_text(path), "arquivo de texto")
    when :email then prepare_email(path, filename, depth:)
    when :archive then prepare_archive(path, filename, depth:)
    when :geo then @sections << geo_notice(filename)
    when :cad then @sections << notice(filename, "é um desenho CAD (DWG/DXF), que a IA não consegue ler", ask: "a planta exportada em PDF")
    when :media then @sections << notice(filename, "é áudio ou vídeo, que a IA não consegue ouvir/assistir", ask: "uma transcrição ou resumo por escrito")
    when :other_archive then @sections << notice(filename, "é um arquivo compactado RAR/7z/TAR, que o sistema não abre", ask: "o mesmo conteúdo em .zip")
    else @sections << notice(filename, "é um formato que o sistema não reconhece")
    end
  end

  # PDF/DOC/DOCX: dentro do limite vai como anexo (a IA lê imagens e layout); acima, só o texto.
  # PDF escaneado grande passa por OCR (Rag::Ocr, cacheado por SHA256 e com teto de páginas).
  def prepare_document(path, filename, from: nil)
    if File.size(path) <= MAX_DOCUMENT_BYTES
      @sources << path.to_s
      return
    end

    note = "texto extraído#{" de #{from}" if from}; o arquivo é grande demais para ser enviado inteiro, então imagens e diagramas dele não estão aqui"
    add_text(filename, extract_text(path, ocr: true), note)
  end

  def prepare_office(path, filename)
    pdf = AttachmentConversions.office_to_pdf(path)
    return @sections << notice(filename, "o sistema não conseguiu converter este documento para PDF", ask: "o arquivo exportado em PDF") unless pdf

    prepare_document(pdf, filename, from: File.extname(filename).delete(".").upcase)
  end

  def prepare_image(path, filename)
    extension = File.extname(filename).downcase
    if NATIVE_IMAGES.include?(extension) && File.size(path) <= MAX_IMAGE_BYTES
      @sources << path.to_s
      return
    end

    jpeg = AttachmentConversions.image_to_jpeg(path)
    if jpeg && File.size(jpeg) <= MAX_IMAGE_BYTES
      @sources << jpeg.to_s
      @sections << "--- A imagem \"#{filename}\" foi convertida para JPEG#{' (só a primeira página)' if extension.start_with?('.tif')} para a IA conseguir ver. ---" unless NATIVE_IMAGES.include?(extension)
    else
      @sections << notice(filename, "o sistema não conseguiu converter esta imagem", ask: "a imagem em JPG ou PNG")
    end
  end

  # E-mail vira texto (quem mandou, pra quem, quando, assunto, corpo) e os anexos dele entram
  # como arquivos normais — é comum o cliente mandar o pedido "no corpo do e-mail + PDF anexo".
  def prepare_email(path, filename, depth:)
    eml = File.extname(filename).downcase == ".msg" ? AttachmentConversions.msg_to_eml(path) : path
    return @sections << notice(filename, "o sistema não conseguiu abrir este e-mail do Outlook", ask: "o e-mail salvo em PDF, ou o texto colado no chat") unless eml

    mail = Mail.read(eml.to_s)
    listed = mail.attachments.map(&:filename).compact
    header = {
      "De" => Array(mail[:from]&.formatted).join(", "), "Para" => Array(mail[:to]&.formatted).join(", "),
      "Cc" => Array(mail[:cc]&.formatted).join(", "), "Data" => mail.date&.strftime("%d/%m/%Y %H:%M"),
      "Assunto" => mail.subject
    }.compact_blank.map { |key, value| "#{key}: #{value}" }.join("\n")
    body = [ header, email_body(mail), ("Anexos do e-mail: #{listed.join(', ')}" if listed.any?) ].compact_blank.join("\n\n")
    add_text(filename, body, "e-mail convertido em texto; os anexos dele, quando legíveis, seguem como arquivos próprios")

    return if depth >= MAX_DEPTH

    directory = Pathname.new("#{eml}.anexos")
    FileUtils.mkdir_p(directory)
    mail.attachments.first(MAX_INNER_FILES).each_with_index do |part, index|
      name = AttachmentConversions.safe_filename(part.filename.presence || "anexo_#{index + 1}")
      data = part.decoded
      next if self.class.category(name) == :image && data.bytesize < MIN_EMAIL_IMAGE_BYTES

      inner = directory.join("#{index + 1}_#{name}")
      File.binwrite(inner, data) unless inner.exist?
      prepare_file(inner, "#{filename} › #{name}", depth: depth + 1)
    end
  end

  def email_body(mail)
    part = mail.multipart? ? (mail.text_part || mail.html_part) : mail
    return "" unless part

    text = part.decoded.to_s.dup.force_encoding(part.charset.presence || "UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
    html = part.mime_type.to_s.include?("html") || (!mail.multipart? && mail.mime_type.to_s.include?("html"))
    html ? Nokogiri::HTML(text).text.gsub(/\n{3,}/, "\n\n").strip : text.strip
  end

  # ZIP: cada arquivo de dentro é preparado como se tivesse sido enviado sozinho. Shapefile
  # dentro do zip é geometria (vai pro módulo geoespacial), não documento pra IA ler.
  def prepare_archive(path, filename, depth:)
    return @sections << notice(filename, "tem pastas compactadas demais umas dentro das outras") if depth >= MAX_DEPTH

    directory = Pathname.new("#{path}.conteudo")
    FileUtils.mkdir_p(directory)
    entries = Zip::File.open(path.to_s) do |zip|
      zip.entries.select(&:file?).reject { |entry| entry.name.start_with?("__MACOSX/") || File.basename(entry.name).start_with?(".") }
        .map do |entry|
          target = directory.join("#{Digest::MD5.hexdigest(entry.name)[0, 8]}_#{AttachmentConversions.safe_filename(entry.name)}")
          if entry.size <= MAX_INNER_BYTES && !target.exist?
            File.open(target, "wb") { |file| IO.copy_stream(entry.get_input_stream, file) }
          end
          [ entry.name, target, entry.size ]
        end
    end

    geo, rest = entries.partition { |name, _, _| self.class.category(name) == :geo }
    @sections << geo_notice(filename, inside: geo.map(&:first)) if geo.any?

    budget = MAX_INNER_BYTES
    analyzed = rest.first(MAX_INNER_FILES).select do |name, target, size|
      next false if size > budget || !target.exist?

      budget -= size
      prepare_file(target, "#{filename} › #{name}", depth: depth + 1)
      true
    end
    skipped = rest.size - analyzed.size
    @sections << "--- O arquivo \"#{filename}\" tem #{rest.size} arquivos; #{skipped} não foram analisados (limite de #{MAX_INNER_FILES} arquivos / #{MAX_INNER_BYTES / 1.megabyte} MB por envio). Avise o consultor. ---" if skipped.positive?
  end

  def add_text(filename, text, note)
    return @sections << notice(filename, "o sistema não conseguiu extrair o conteúdo") if text.blank?

    @sections << <<~TEXT
      --- CONTEÚDO DO ARQUIVO "#{filename}" (#{note}) ---
      #{text.truncate(MAX_TEXT_CHARS)}
      --- FIM DE "#{filename}" ---
    TEXT
  end

  # plain_text, não text: o extrator marca títulos com um caractere de controle que só interessa
  # ao chunker do RAG e que a API do provider rejeita.
  def extract_text(path, ocr: false)
    result = Rag::TextExtractor.new(path.to_s, ocr: ocr).call
    result.ok? ? result.plain_text : nil
  rescue StandardError => e
    Rails.logger.error("[AttachmentPreparer] falha ao extrair #{path}: #{e.class} #{e.message}")
    nil
  end

  def read_text(path)
    raw = File.binread(path)
    text = raw.dup.force_encoding(Encoding::UTF_8)
    text = raw.encode(Encoding::UTF_8, Encoding::Windows_1252, invalid: :replace, undef: :replace) unless text.valid_encoding?
    File.extname(path.to_s).downcase.in?(%w[.html .htm]) ? Nokogiri::HTML(text).text.gsub(/\n{3,}/, "\n\n") : text
  end

  def geo_notice(filename, inside: nil)
    what = inside ? "contém arquivo(s) geoespacial(is) (#{inside.first(5).join(', ')})" : "é um arquivo geoespacial"
    "--- O arquivo \"#{filename}\" #{what}. Geometria é processada pelo módulo geoespacial do sistema " \
    "(área, perímetro, municípios, mapa), não lida como texto. Se o consultor quer que ela seja a área " \
    "do projeto, ela entra por lá sozinha; não deduza nada do conteúdo pelo nome. ---"
  end

  # Falhar em silêncio é pior do que não ter o arquivo: sem anexo E sem aviso, a IA analisa o
  # que não recebeu — e deduz o conteúdo pelo nome do arquivo com toda a confiança.
  def notice(filename, reason, ask: "uma versão em PDF")
    Rails.logger.warn("[AttachmentPreparer] #{filename}: #{reason}")
    "--- O arquivo \"#{filename}\" foi enviado pelo consultor, mas #{reason}. NÃO deduza o conteúdo " \
    "dele pelo nome do arquivo nem finja que o leu: diga ao consultor que esse arquivo não pôde ser " \
    "lido e peça #{ask}. ---"
  end
end
