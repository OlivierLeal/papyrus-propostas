# Conversões de arquivo que o provider de IA não aceita como anexo (2026-09-27, levantamento
# "quais arquivos eles podem enviar e o sistema não mapear"). Cada método recebe um caminho em
# disco e devolve o caminho do arquivo convertido, ou nil se a ferramenta não existe/falhou —
# quem chama transforma nil num aviso explícito para a IA, nunca em silêncio.
#
# Tudo roda sobre um cache em disco (tmp/attachment_cache/<checksum>/): o chat pode montar o
# conteúdo da mesma mensagem mais de uma vez (cada volta de ferramenta), e converter um .pptx de
# 20 MB no LibreOffice a cada vez seria segundos jogados fora.
#
# Ferramentas de sistema usadas (instalação no servidor: ver CLAUDE.md seção 12):
#   soffice (LibreOffice writer+impress+calc), magick/convert (ImageMagick), heif-convert ou
#   heif-dec (libheif-examples), msgconvert (libemail-outlook-message-perl), ogr2ogr (gdal-bin),
#   tesseract + tesseract-ocr-por (OCR de PDF escaneado grande), pdftotext (poppler-utils).
# Ferramenta ausente não quebra nada: o arquivo vira um aviso pedindo outro formato.
module AttachmentConversions
  TIMEOUT = 120
  CACHE_ROOT = Rails.root.join("tmp/attachment_cache")

  # Lado maior de uma imagem convertida/reduzida. Suficiente pra ler foto de campo, planta e
  # print; o Bedrock recusa imagem acima de ~3,75 MB.
  MAX_IMAGE_SIDE = 2000

  module_function

  # Baixa o blob pro cache uma vez só (chave = checksum do conteúdo) e devolve o caminho.
  def materialize(attachment)
    directory = CACHE_ROOT.join(safe_key(attachment.blob.checksum))
    FileUtils.mkdir_p(directory)
    path = directory.join(safe_filename(attachment.filename.to_s))
    unless path.exist? && path.size == attachment.byte_size
      File.open(path, "wb") { |file| attachment.download { |chunk| file.write(chunk) } }
    end
    path
  end

  # PPTX/PPT/ODP/ODT/RTF… → PDF pelo LibreOffice headless. PDF preserva slides e imagens, que a
  # IA lê nativamente — melhor que só o texto.
  def office_to_pdf(path)
    output = Pathname.new("#{path}.pdf")
    return output if output.exist?

    Dir.mktmpdir("office") do |dir|
      # Perfil próprio por conversão: duas instâncias do LibreOffice com o mesmo perfil de
      # usuário travam uma a outra (jobs em paralelo).
      profile = "-env:UserInstallation=file://#{dir}/profile"
      ok = run("soffice", profile, "--headless", "--convert-to", "pdf", "--outdir", dir, path.to_s)
      converted = Dir.glob(File.join(dir, "*.pdf")).first
      return nil unless ok && converted

      FileUtils.mv(converted, output)
    end
    output
  end

  # Qualquer imagem (HEIC do iPhone, TIFF escaneado, BMP, ou JPG/PNG grande demais) → JPEG com
  # no máximo MAX_IMAGE_SIDE de lado. TIFF de várias páginas: só a primeira (o aviso diz isso).
  def image_to_jpeg(path)
    output = Pathname.new("#{path}.jpg")
    return output if output.exist?

    source = path.to_s
    if heif?(path)
      # ImageMagick nem sempre vem com suporte a HEIC; o heif-convert (libheif) é o caminho certo.
      intermediate = "#{path}.heif.jpg"
      # heif-convert (libheif até 1.16) virou heif-dec nas versões novas (Ubuntu 24.04+).
      decoder = %w[heif-convert heif-dec].find { |tool| available?(tool) }
      source = intermediate if decoder && run(decoder, path.to_s, intermediate) && File.exist?(intermediate)
    end

    ok = run(imagemagick, "#{source}[0]", "-auto-orient", "-resize", "#{MAX_IMAGE_SIDE}x#{MAX_IMAGE_SIDE}>",
      "-quality", "85", "jpeg:#{output}")
    ok && output.exist? ? output : nil
  end

  # .msg (Outlook) → .eml (MIME), que o Ruby lê com a gem mail.
  def msg_to_eml(path)
    output = Pathname.new("#{path}.eml")
    return output if output.exist?

    run("msgconvert", "--outfile", output.to_s, path.to_s) && output.exist? ? output : nil
  end

  # Shapefile (zipado), GeoJSON, GeoPackage, GML → KML pelo GDAL, pra entrar no mesmo
  # processamento geoespacial do KMZ (KmzGeometryExtractor). Reprojeta pra WGS84 (KML exige).
  def geo_to_kml(path)
    output = Pathname.new("#{path}.kml")
    return output if output.exist?

    source = path.to_s.downcase.end_with?(".zip") ? "/vsizip/#{path}" : path.to_s
    run("ogr2ogr", "--config", "SHAPE_RESTORE_SHX", "YES", "-f", "KML", "-t_srs", "EPSG:4326", output.to_s, source) && output.exist? ? output : nil
  end

  def available?(tool)
    system("which", tool, out: File::NULL, err: File::NULL)
  end

  def imagemagick
    available?("magick") ? "magick" : "convert"
  end

  def heif?(path)
    %w[.heic .heif].include?(File.extname(path.to_s).downcase)
  end

  # Nome de arquivo seguro pro disco, mantendo a extensão (é ela que decide o tratamento).
  def safe_filename(name)
    base = File.basename(name.to_s).gsub(/[^\p{L}\p{N}._ -]/, "_").strip
    base.presence || "arquivo"
  end

  def safe_key(key)
    key.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
  end

  def run(*command)
    _out, err, status = Timeout.timeout(TIMEOUT) { Open3.capture3(*command) }
    Rails.logger.warn("[AttachmentConversions] #{command.first} falhou: #{err.to_s.lines.first&.strip}") unless status.success?
    status.success?
  rescue Errno::ENOENT
    Rails.logger.warn("[AttachmentConversions] ferramenta ausente no servidor: #{command.first}")
    false
  rescue Timeout::Error
    Rails.logger.warn("[AttachmentConversions] #{command.first} passou de #{TIMEOUT}s")
    false
  end
end
