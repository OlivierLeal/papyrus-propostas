module Rag
  # Etapa 2 do pipeline: extrai o texto bruto de um documento do acervo.
  #
  # Boa parte do acervo da Papyrus é PDF escaneado (sem camada de texto): nesses casos o
  # pdftotext devolve um punhado de caracteres de ruído. Embedar isso envenenaria o índice
  # com chunks vazios, então o extrator CLASSIFICA em vez de fingir que deu certo — quem
  # decide o que fazer com um :needs_ocr é a Rag::Ingestion.
  class TextExtractor
    # Página de proposta com texto real fica na casa de 1000 chars; escaneada fica em 15-30.
    # 200 separa os dois mundos com folga larga dos dois lados.
    MIN_CHARS_PER_PAGE = 200

    # Cabeçalho/rodapé (endereço, telefone, site) se repete em toda página do modelo Papyrus.
    # Linha curta que aparece em pelo menos 30% das páginas é boilerplate, não conteúdo.
    BOILERPLATE_PAGE_RATIO = 0.3
    BOILERPLATE_MAX_LENGTH = 120
    MIN_BOILERPLATE_PAGES = 2

    STATUSES = %i[ok ocr needs_ocr empty unsupported].freeze

    # Arquivo corrompido é regra, não exceção, num acervo de anos. Erro tipado para a
    # Rag::Ingestion registrar o arquivo como falho e seguir com o resto do lote.
    class ExtractionError < StandardError; end

    # LibreOffice headless costuma converter em poucos segundos, mas trava em arquivo
    # corrompido — sem teto, um único .doc ruim paralisa a ingestão do acervo inteiro.
    LIBREOFFICE_TIMEOUT = 90

    Result = Data.define(:text, :pages, :page_count, :chars_per_page, :status) do
      def ok? = status.in?(%i[ok ocr])

      # Texto sem os marcadores internos de seção — para qualquer uso fora do SectionChunker
      # (envio a uma API, gravação em banco, exibição).
      def plain_text = text.gsub(SectionChunker::MARKED_HEADING_PREFIX, "")

      def from_ocr? = status == :ocr
      def needs_ocr? = status == :needs_ocr
    end

    def initialize(path, ocr: false)
      @path = Pathname.new(path)
      @ocr = ocr
    end

    def call
      pages = case @path.extname.downcase
      when ".pdf"  then extract_pdf
      when ".docx" then extract_docx
      when ".doc"  then extract_legacy_doc
      else return unsupported_result
      end

      pages = strip_boilerplate(pages)
      result = build_result(pages)

      # O OCR é caro (~4s por página), então só entra quando a extração normal já concluiu
      # que não há texto — nunca "por precaução" num PDF que já tem camada de texto.
      result.needs_ocr? && @ocr ? recover_with_ocr : result
    end

    private

    # .doc (Word 97-2003) é binário, não zip. Em vez de descartar, converte para .docx com o
    # LibreOffice headless e reentra no extrator normal — acervo antigo costuma ter bastante
    # arquivo nesse formato, e é texto nativo (não precisa de OCR), então vale o segundo passo.
    def extract_legacy_doc
      Dir.mktmpdir("rag-doc") do |dir|
        _out, err, status = Timeout.timeout(LIBREOFFICE_TIMEOUT) do
          Open3.capture3("soffice", "--headless", "--convert-to", "docx", "--outdir", dir, @path.to_s)
        end

        converted = Dir.glob(File.join(dir, "*.docx")).first
        unless status.success? && converted
          Rails.logger.warn("[Rag::TextExtractor] conversão de #{@path} falhou: #{err}")
          return []
        end

        self.class.new(converted).send(:extract_docx)
      end
    rescue Timeout::Error
      Rails.logger.warn("[Rag::TextExtractor] LibreOffice travou em #{@path}")
      []
    end

    # Tanto o pdftotext (via pipe) quanto o rubyzip devolvem string em ASCII-8BIT. Sem marcar
    # o encoding, qualquer regex com \p{Lu} estoura em documento com acento — ou seja, em
    # todos eles. O scrub descarta byte inválido de PDF mal formado em vez de abortar o lote.
    def normalize(string)
      string.dup.force_encoding(Encoding::UTF_8).scrub("")
    end

    # Texto vindo de OCR fica com status próprio: no relatório importa saber que aquele trecho
    # foi reconhecido de imagem, porque a qualidade é sempre inferior à do texto nativo.
    def recover_with_ocr
      pages = Ocr.new(@path).call
      build_result(strip_boilerplate(pages)).with(status: :ocr)
    rescue Ocr::Unavailable => e
      Rails.logger.warn("[Rag::TextExtractor] OCR indisponível: #{e.message}")
      build_result([])
    end

    def unsupported_result
      Result.new(text: "", pages: [], page_count: 0, chars_per_page: 0, status: :unsupported)
    end

    def extract_pdf
      out, err, status = Open3.capture3("pdftotext", "-layout", "-enc", "UTF-8", @path.to_s, "-")
      raise ExtractionError, "pdftotext falhou: #{err.lines.first&.strip}" unless status.success?

      # pdftotext separa páginas com form feed.
      normalize(out).split("\f").map { |page| mark_table_columns(page) }
    end

    # DOCX é um zip com XML dentro — mesma técnica já usada em ProposalDocxFiller e no KMZ.
    #
    # Três armadilhas que só aparecem em arquivo real da Papyrus:
    #
    #   1. Numeração de seção é automática (w:numPr): o "3." de "3. OBJETIVO DOS SERVIÇOS" é
    #      renderizado pelo Word e NÃO existe no texto. Quem marca o título é o estilo do
    #      parágrafo (Ttulo1/Heading1), então a numeração é reconstruída pelo nível.
    #   2. Raspar as tags com um gsub deixa o conteúdo de elementos que não são texto —
    #      coordenadas de caixa de texto (wp:posOffset) viram lixo como "-1080135-150304500".
    #      Por isso o texto sai só dos nós <w:t>.
    #   3. mc:Fallback repete todo o conteúdo de caixas de texto, duplicando a capa.
    def extract_docx = [ docx_text(read_document_xml) ]

    def docx_text(xml)
      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!
      doc.xpath("//AlternateContent/Fallback").each(&:remove)
      doc.xpath("//instrText").each(&:remove)  # instrução de campo ("PAGE \\* MERGEFORMAT")

      numbering = HeadingNumbering.new
      body = doc.at_xpath("//body") || doc.root
      lines = body.elements.flat_map { |node| render_node(node, numbering) }

      normalize(lines.join("\n")).gsub(/\n{3,}/, "\n\n")
    end

    def render_node(node, numbering)
      case node.name
      when "p"   then render_paragraph(node, numbering)
      when "tbl" then render_table(node)
      else []
      end
    end

    def render_paragraph(paragraph, numbering)
      text = paragraph.xpath(".//t").map(&:text).join.squish
      level = heading_level(paragraph.at_xpath("./pPr/pStyle/@val")&.value)

      return [ text ] unless level && text.present?

      # Alguns títulos já vêm com o número digitado ("6.1 OBRIGAÇÕES DA PAPYRUS"); prefixar
      # a numeração reconstruída nesses casos produziria "5.1 6.1 OBRIGAÇÕES".
      number = numbering.next(level, keep: text[SectionChunker::LEADING_NUMBER, 1])

      [ "", "#{SectionChunker::HEADING_MARKER}#{number} #{text.sub(SectionChunker::LEADING_NUMBER, '')}", "" ]
    end

    # Cada linha da tabela vira uma linha de texto com as células separadas — mesma forma que
    # o mark_table_columns produz para o PDF, para o chunker enxergar os dois do mesmo jeito.
    def render_table(table)
      table.xpath("./tr").map do |row|
        row.xpath("./tc").map { |cell| cell_text(cell) }
          .reject(&:empty?)
          .join(" | ")
      end.reject(&:empty?)
    end

    # Uma célula pode conter vários parágrafos — no acervo, listas inteiras de diagnóstico
    # ambiental moram numa célula só. Concatenar sem separador cola as palavras e inventa
    # tokens que não existem ("Meio físicoÁreas de influênciaClima"), o que degrada o
    # embedding justamente do conteúdo mais técnico.
    def cell_text(cell)
      paragraphs = cell.xpath("./p").map { |paragraph| paragraph.xpath(".//t").map(&:text).join.squish }
      paragraphs = [ cell.xpath(".//t").map(&:text).join.squish ] if paragraphs.empty?

      paragraphs.reject(&:empty?).join(" · ")
    end

    HEADING_STYLE = /\A(?:t[íi]tulo|ttulo|heading|title)\s*(\d)?\z/i

    def heading_level(style)
      match = HEADING_STYLE.match(style.to_s)
      return nil unless match

      (match[1] || 1).to_i
    end

    # Reconstrói a numeração hierárquica que o Word renderiza a partir do nível do estilo.
    class HeadingNumbering
      def initialize
        @counters = Hash.new(0)
      end

      def next(level, keep: nil)
        return keep.delete_suffix(".") if keep.present?

        @counters[level] += 1
        @counters.each_key { |other| @counters[other] = 0 if other > level }
        (1..level).map { |l| @counters[l] }.reject(&:zero?).join(".")
      end
    end

    def read_document_xml
      Zip::File.open(@path.to_s) { |zip| zip.get_entry("word/document.xml").get_input_stream.read }
    rescue Zip::Error, Errno::ENOENT => e
      raise ExtractionError, "DOCX ilegível: #{e.message}"
    end

    # O -layout do pdftotext alinha colunas de tabela com corridas de espaço. Sem marcar a
    # fronteira, "Maria Nogueira        Bióloga        CRBio: 36.780" vira uma frase só e o
    # embedding perde a noção de que são três campos distintos.
    TABLE_COLUMN_GAP = /[ \t]{3,}/

    def mark_table_columns(page)
      page.lines.map do |line|
        line.match?(TABLE_COLUMN_GAP) ? "#{line.strip.gsub(TABLE_COLUMN_GAP, ' | ')}\n" : line
      end.join
    end

    def strip_boilerplate(pages)
      return pages if pages.length < 3

      counts = Hash.new(0)
      pages.each do |page|
        page.lines.map { |line| line.squish }.uniq.each do |line|
          counts[line] += 1 if line.present? && line.length <= BOILERPLATE_MAX_LENGTH
        end
      end

      # O piso de 2 é essencial: em um documento de 3 páginas a razão arredonda para 1, e aí
      # QUALQUER linha vira "boilerplate" — o filtro apaga o documento inteiro em silêncio.
      threshold = [ (pages.length * BOILERPLATE_PAGE_RATIO).ceil, MIN_BOILERPLATE_PAGES ].max
      boilerplate = counts.select { |_line, count| count >= threshold }.keys.to_set

      pages.map do |page|
        page.lines.reject { |line| boilerplate.include?(line.squish) }.join
      end
    end

    def build_result(pages)
      text = pages.join("\n").gsub(/\n{3,}/, "\n\n").strip
      page_count = [ pages.length, pdf_page_count, 1 ].compact.max
      useful_chars = text.gsub(/\s/, "").length

      status = if text.blank? && paginated?
        # PDF sem UMA letra sequer é o caso clássico de "Print To PDF": o conteúdo está lá,
        # rasterizado. Chamar isso de :empty faria descartar um documento inteiro por engano.
        :needs_ocr
      elsif text.blank?
        :empty
      elsif paginated? && useful_chars.fdiv(page_count) < MIN_CHARS_PER_PAGE
        :needs_ocr
      elsif !paginated? && useful_chars < MIN_CHARS_PER_PAGE
        # DOCX sem paginação: um arquivo que só tem imagens dentro cai aqui.
        :needs_ocr
      else
        :ok
      end

      Result.new(
        text:,
        pages:,
        page_count:,
        chars_per_page: useful_chars.fdiv(page_count).round,
        status:
      )
    end

    # Só o PDF vem paginado pelo pdftotext (form feed); DOCX sai como um bloco só.
    def paginated? = @path.extname.casecmp?(".pdf")

    # Quando o PDF é todo imagem, o pdftotext não devolve nem os form feeds e a contagem de
    # páginas se perde — mas ela é justamente o que dimensiona o OCR que virá depois.
    def pdf_page_count
      return nil unless paginated?

      out, _err, status = Open3.capture3("pdfinfo", @path.to_s)
      status.success? ? out[/^Pages:\s*(\d+)/, 1]&.to_i : nil
    rescue StandardError
      nil
    end
  end
end
