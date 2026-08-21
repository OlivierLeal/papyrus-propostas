module Rag
  # Recupera o texto de um PDF que é só imagem — o caso "Microsoft: Print To PDF", comum no
  # acervo da Papyrus (os Procedimentos Operacionais da Petrobras são todos assim).
  #
  # Renderiza página a página com pdftoppm e passa cada uma pelo tesseract. Não usa o
  # ocrmypdf de propósito: aqui só interessa o texto, não gerar um PDF pesquisável — e assim
  # o pipeline não depende da stack Python dele (que, nesta máquina, está quebrada por
  # conflito de versão do pikepdf).
  #
  # É a etapa mais lenta do pipeline (~4s por página), então o resultado é cacheado pelo
  # SHA256 do arquivo: reprocessar o acervo não paga o OCR de novo.
  class Ocr
    LANGUAGE = "por"
    # 300 DPI é o mínimo recomendado pelo tesseract para texto impresso; abaixo disso a taxa
    # de erro em português (com acento) sobe rápido.
    DPI = 300
    # --psm 1 deixa o tesseract detectar o layout da página sozinho: o acervo mistura texto
    # corrido, tabelas e mapas com legenda, e um modo fixo erraria em algum deles.
    PAGE_SEGMENTATION_MODE = "1"

    # Teto de segurança: um PDF de 800 páginas travaria a ingestão por quase uma hora.
    MAX_PAGES = 200

    # Cada página tem seu próprio timeout — página com mapa denso ocasionalmente trava.
    PAGE_TIMEOUT = 120

    class Unavailable < StandardError; end

    def self.available?
      @available = system("which", "tesseract", "pdftoppm", out: File::NULL, err: File::NULL) if @available.nil?
      @available
    end

    def initialize(path, max_pages: MAX_PAGES)
      @path = Pathname.new(path)
      @max_pages = max_pages
    end

    # Devolve as páginas reconhecidas, na ordem. Página que falhou entra como string vazia
    # para não desalinhar a numeração em relação ao PDF original.
    def call
      raise Unavailable, "tesseract/pdftoppm não instalados" unless self.class.available?

      cached = read_cache
      return cached if cached

      pages = Dir.mktmpdir("rag-ocr") { |dir| recognize_all(dir) }
      write_cache(pages)
      pages
    end

    private

    def recognize_all(dir)
      prefix = File.join(dir, "pg")
      render(prefix)

      Dir.glob("#{prefix}-*.png").sort.map { |image| recognize(image) }
    end

    def render(prefix)
      _out, err, status = Open3.capture3(
        "pdftoppm", "-r", DPI.to_s, "-png", "-f", "1", "-l", @max_pages.to_s, @path.to_s, prefix
      )
      raise TextExtractor::ExtractionError, "pdftoppm falhou: #{err.lines.first&.strip}" unless status.success?
    end

    def recognize(image)
      out, _err, status = Timeout.timeout(PAGE_TIMEOUT) do
        Open3.capture3("tesseract", image, "-", "-l", LANGUAGE, "--psm", PAGE_SEGMENTATION_MODE)
      end
      return "" unless status.success?

      out.dup.force_encoding(Encoding::UTF_8).scrub("")
    rescue Timeout::Error
      Rails.logger.warn("[Rag::Ocr] tesseract travou em #{File.basename(image)} de #{@path.basename}")
      ""
    end

    # ---- cache ----------------------------------------------------------------
    # O OCR é determinístico para um mesmo arquivo, então o SHA256 é chave suficiente. Fica
    # em tmp/ de propósito: é derivado, dá para apagar e regenerar a qualquer momento.

    def cache_path
      @cache_path ||= begin
        directory = Rails.root.join("tmp/rag_ocr_cache")
        FileUtils.mkdir_p(directory)
        directory.join("#{Digest::SHA256.file(@path).hexdigest}.json")
      end
    end

    def read_cache
      return nil unless cache_path.exist?

      JSON.parse(cache_path.read)
    rescue JSON::ParserError
      nil
    end

    def write_cache(pages)
      cache_path.write(JSON.generate(pages))
    end
  end
end
