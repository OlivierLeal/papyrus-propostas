# Os documentos do órgão que acompanham a proposta como ANEXOS (2026-10). Começou como "o TR vem
# como anexo, não no escopo" (Sara); depois do teste na proposta 34 (o "TR" era a portaria da
# licença, escaneada): o anexo leva o nome do que o documento É ("ANEXO I – PORTARIA Nº 25.288/2022"),
# documento comercial/contratual não entra, e escaneado vai como IMAGEM das páginas.
#
# - .docx e PDF com texto: TEXTO EDITÁVEL reescrito no padrão da Papyrus (pedido da Papyrus) —
#   títulos, parágrafos, listas e tabelas (.docx); em PDF, tabela vira texto corrido e figura vira
#   FIGURE_PLACEHOLDER. Não é cópia fiel da diagramação: juntar o original quebraria estilos.
# - PDF escaneado: as PÁGINAS COMO IMAGEM (150 dpi), retrato ou paisagem conforme a página. OCR
#   ficou de fora de propósito: em ato oficial (carimbo, assinatura, formulário) ele erra número e
#   lê lixo, e citação errada de um ato do órgão é pior que não anexar.
# - .doc/.odt/.rtf: LibreOffice → PDF e segue como PDF.
# - Acima de MAX_PAGES: o anexo entra só com o título e a indicação de arquivo à parte.
#
# Uso: TermOfReferenceAnnex.build(attachments, profiles:) → Result(annexes, skipped);
#      ProposalDocxFiller#append_annexes! monta no .docx.
module TermOfReferenceAnnex
  TITLE = "ANEXO I – TERMO DE REFERÊNCIA" # o mais comum; o real vem do tipo do documento (Profile)
  FIGURE_PLACEHOLDER = "[figura do documento original]"
  W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  MAX_PAGES = 40
  ROMAN = %w[I II III IV V VI VII VIII IX X].freeze

  # Tipos que a IA escolhe (ProcessTrJob). Os de ANNEXABLE_TYPES vão pra proposta; os outros
  # (contratual/comercial) só servem de leitura e nunca viram anexo.
  ANNEXABLE_TYPES = [ "Termo de Referência", "Portaria", "Licença", "Parecer Técnico", "Ofício", "Instrução Normativa",
                      "Resolução", "Decreto", "Notificação", "Autorização", "Norma Técnica", "Outro documento do órgão" ].freeze
  NON_ANNEXABLE_TYPES = [ "Minuta de contrato", "Condições gerais de compra/contratação", "Edital/Carta-convite",
                          "Proposta comercial", "Outro documento comercial" ].freeze
  TYPES = (ANNEXABLE_TYPES + NON_ANNEXABLE_TYPES).freeze

  Block = Data.define(:kind, :text, :rows) do # kind: :heading, :paragraph, :list, :table, :figure
    def self.of(kind, text = nil, rows: nil) = new(kind:, text:, rows:)
  end

  # Uma página escaneada: JPEG + tamanho da página em pontos (decide retrato × paisagem).
  Page = Data.define(:jpeg, :width_pt, :height_pt) do
    def landscape? = width_pt > height_pt
  end

  # O que é o documento. `tipo` vem da IA (ProcessTrJob) ou, sem ela, do nome do arquivo e da 1ª página.
  Profile = Data.define(:tipo, :numero, :anexar, :motivo) do
    def title_text
      name = tipo == "Outro documento do órgão" ? "Documento de referência" : tipo
      [ name.upcase, (" Nº #{numero}" if numero.present?) ].join
    end

    def label_text
      name = tipo == "Outro documento do órgão" ? "Documento de referência" : tipo
      [ name, (" nº #{numero}" if numero.present?) ].join
    end
  end

  # blocks (texto) ou pages (imagem); `separate` quando passa de MAX_PAGES (só título + aviso).
  Annex = Data.define(:number, :profile, :filename, :blocks, :pages, :page_count) do
    def title = "ANEXO #{number} – #{profile.title_text}"
    def label = "#{profile.label_text} (Anexo #{number})"
    def separate? = page_count.to_i > MAX_PAGES
    def images? = pages.present?
    def content_xml = separate? ? Writer.new([ Block.of(:paragraph, "Documento com #{page_count} páginas, enviado em arquivo à parte: #{filename}.") ]).call : Writer.new(blocks).call
  end

  Result = Data.define(:annexes, :skipped) do
    def any? = annexes.any?
  end

  module_function

  # profiles: Conversation#reference_document_profiles ({ blob_id => {...} }).
  def build(attachments, profiles: {})
    plan(attachments, profiles: profiles) do |attachment, profile, number|
      content = Reader.new(attachment).call
      next nil if content.blocks.blank? && content.pages.blank? && content.page_count.to_i <= MAX_PAGES

      Annex.new(number: number, profile: profile, filename: attachment.filename.to_s, blocks: content.blocks,
        pages: content.pages, page_count: content.page_count)
    end
  end

  # Só os nomes ("Portaria nº 25.288/2022 (Anexo I)"), sem ler o conteúdo — pro estado da proposta
  # que a IA lê a cada turno.
  def labels(attachments, profiles: {})
    plan(attachments, profiles: profiles) do |attachment, profile, number|
      Annex.new(number: number, profile: profile, filename: attachment.filename.to_s, blocks: [], pages: [], page_count: 0)
    end
  end

  def plan(attachments, profiles:)
    annexes = []
    skipped = []
    Array(attachments).each do |attachment|
      profile = profile_for(attachment, profiles)
      unless profile.anexar
        skipped << [ attachment.filename.to_s, profile.tipo ]
        next
      end
      annex = yield(attachment, profile, ROMAN.fetch(annexes.size, (annexes.size + 1).to_s))
      annexes << annex if annex
    end
    Result.new(annexes: annexes, skipped: skipped)
  end

  def profile_for(attachment, profiles)
    stored = profiles.to_h[attachment.blob_id.to_s] || profiles.to_h[attachment.blob_id]
    return Profile.new(tipo: stored["tipo"], numero: stored["numero"].presence, anexar: stored["anexar"] != false, motivo: stored["motivo"]) if stored.is_a?(Hash) && TYPES.include?(stored["tipo"])

    Guess.new(attachment).call
  end

  # Sem a leitura da IA (documento enviado antes de existir isto): adivinha pelo nome do arquivo e
  # pela 1ª página (só PDF com texto/.docx — nunca OCR aqui, roda na hora de gerar).
  class Guess
    PATTERNS = [
      [ "Minuta de contrato", /minuta|contrato\b/i ],
      [ "Condições gerais de compra/contratação", /condi[çc][õo]es\s+gerais|termos\s+e\s+condi[çc][õo]es/i ],
      [ "Edital/Carta-convite", /edital|carta[\s_-]*convite|\bcc\s?\d+/i ],
      [ "Proposta comercial", /proposta\s+(t[ée]cnica|comercial)/i ],
      [ "Termo de Referência", /termo\s+de\s+refer[êe]ncia|\bTR\b/ ],
      [ "Instrução Normativa", /instru[çc][ãa]o\s+normativa/i ],
      [ "Portaria", /portaria/i ], [ "Resolução", /resolu[çc][ãa]o/i ], [ "Decreto", /decreto/i ],
      [ "Licença", /licen[çc]a/i ], [ "Parecer Técnico", /parecer/i ], [ "Ofício", /of[íi]cio/i ],
      [ "Notificação", /notifica[çc][ãa]o/i ], [ "Autorização", /autoriza[çc][ãa]o/i ]
    ].freeze
    # "Portaria 25.288_2022", "nº 25.288/2022", "Portaria nº 11.292 de 2016" não (só número/ano colados).
    NUMBER = /\A\W*(?:n[º°o.]?\s*)?(\d{1,3}(?:\.\d{3})+|\d+)\s*[\/_\s-]\s*(\d{4}|\d{2})\b/i

    def initialize(attachment)
      @attachment = attachment
    end

    def call
      name = @attachment.filename.base.tr("_", " ")
      head = first_page_text
      tipo, regex = type_in(name) || type_in(head)
      tipo ||= "Termo de Referência" # veio no campo TR e nada diz o contrário
      numero = regex && (number_after(name, regex) || number_after(head, regex))
      Profile.new(tipo: tipo, numero: numero, anexar: ANNEXABLE_TYPES.include?(tipo), motivo: nil)
    end

    private

    def type_in(text) = PATTERNS.find { |_, pattern| text.match?(pattern) }

    def number_after(text, regex)
      match = text.match(regex) or return nil
      found = text[match.end(0)..].to_s[0, 40].match(NUMBER)
      found && "#{found[1]}/#{found[2]}"
    end

    def first_page_text
      path = AttachmentConversions.materialize(@attachment)
      case File.extname(path.to_s).downcase
      when ".pdf"
        out, _err, status = Open3.capture3("pdftotext", "-l", "1", "-enc", "UTF-8", path.to_s, "-")
        status.success? ? out.force_encoding(Encoding::UTF_8).scrub("")[0, 1500] : ""
      when ".docx"
        Zip::File.open(path.to_s) { |zip| Nokogiri::XML(zip.read("word/document.xml")).xpath("//*[local-name()='t']").map(&:text).join(" ")[0, 1500] }
      else ""
      end
    rescue StandardError
      ""
    end
  end

  class Reader
    # Linha de número de página/rodapé repetido ("Página 3 de 12", "12", "3/12").
    PAGE_NUMBER = /\A(p[áa]g(ina)?\.?\s*)?\d{1,4}(\s*(de|\/)\s*\d{1,4})?\z/i
    NUMBERED_HEADING = /\A\d{1,2}(\.\d{1,2}){0,3}\.?\s+\S/
    LIST_ITEM = /\A(?:[•●▪◦\-–—*]|[a-z]\)|[ivx]{1,4}\)|\d{1,2}\))\s+/i
    MAX_HEADING_LENGTH = 110
    # Linha curta ou repetida em 30%+ das páginas é cabeçalho/rodapé do órgão (mesma regra do acervo).
    BOILERPLATE_RATIO = 0.3

    def initialize(attachment)
      @attachment = attachment
    end

    Content = Data.define(:blocks, :pages, :page_count)
    DPI = 150

    def call
      path = AttachmentConversions.materialize(@attachment)
      case File.extname(path.to_s).downcase
      when ".docx" then Content.new(blocks: docx_blocks(path), pages: [], page_count: nil)
      when ".pdf" then pdf_content(path)
      when ".doc", ".odt", ".rtf"
        pdf = AttachmentConversions.office_to_pdf(path)
        pdf ? pdf_content(pdf) : empty
      else empty
      end
    rescue StandardError => e
      Rails.logger.error("[TermOfReferenceAnnex] não consegui ler #{@attachment.filename}: #{e.class} #{e.message}")
      empty
    end

    private

    # --- DOCX ---------------------------------------------------------------------------------
    HEADING_STYLE = /\A(?:t[íi]tulo|ttulo|heading|title)\s*\d?\z/i

    def docx_blocks(path)
      xml = Zip::File.open(path.to_s) { |zip| zip.read("word/document.xml") }
      doc = Nokogiri::XML(xml)
      doc.remove_namespaces!
      doc.xpath("//AlternateContent/Fallback").each(&:remove)
      doc.xpath("//instrText").each(&:remove)
      body = doc.at_xpath("//body")
      return [] unless body

      body.elements.flat_map do |node|
        case node.name
        when "p" then docx_paragraph(node)
        when "tbl" then docx_table(node)
        else []
        end
      end
    end

    def docx_paragraph(paragraph)
      text = paragraph.xpath(".//t").map(&:text).join.squish
      figure = paragraph.at_xpath(".//drawing|.//pict").present?
      blocks = []
      if text.present?
        style = paragraph.at_xpath("./pPr/pStyle/@val")&.value.to_s
        kind = if style.match?(HEADING_STYLE) then :heading
        elsif paragraph.at_xpath("./pPr/numPr") then :list
        else :paragraph
        end
        blocks << Block.of(kind, text)
      end
      blocks << Block.of(:figure, FIGURE_PLACEHOLDER) if figure
      blocks
    end

    def docx_table(table)
      rows = table.xpath("./tr").map do |row|
        row.xpath("./tc").map do |cell|
          cell.xpath("./p").map { |p| p.xpath(".//t").map(&:text).join.squish }.reject(&:empty?).join("\n")
        end
      end.reject { |cells| cells.all?(&:empty?) }
      rows.empty? ? [] : [ Block.of(:table, rows: rows) ]
    end

    def empty = Content.new(blocks: [], pages: [], page_count: 0)

    # --- PDF ----------------------------------------------------------------------------------
    # Escaneado (menos de 200 caracteres de texto por página, a mesma régua do acervo) vai como
    # imagem; com texto, vira texto editável.
    def pdf_content(path)
      sizes = page_sizes(path)
      pages = pdf_text_pages(path)
      count = [ sizes.size, pages.size ].max
      return Content.new(blocks: [], pages: [], page_count: count) if count > MAX_PAGES

      if pages.join.gsub(/\s/, "").length < 200 * [ count, 1 ].max
        Content.new(blocks: [], pages: page_images(path, sizes), page_count: count)
      else
        Content.new(blocks: text_blocks(path, pages), pages: [], page_count: count)
      end
    end

    def text_blocks(path, pages)
      figures = pages_with_figures(path)
      strip_repeated_lines(pages).each_with_index.flat_map do |page, index|
        blocks = page_blocks(page)
        blocks << Block.of(:figure, FIGURE_PLACEHOLDER) if figures[index + 1]
        blocks
      end
    end

    # Tamanho de cada página em pontos, já com a rotação aplicada (o pdftoppm também aplica).
    def page_sizes(path)
      out, _err, status = Open3.capture3("pdfinfo", "-f", "1", "-l", "9999", path.to_s)
      return [] unless status.success?

      sizes = {}
      rotations = {}
      out.each_line do |line|
        if (m = line.match(/\APage\s+(\d+)\s+size:\s+([\d.]+)\s+x\s+([\d.]+)/))
          sizes[m[1].to_i] = [ m[2].to_f, m[3].to_f ]
        elsif (m = line.match(/\APage\s+(\d+)\s+rot:\s+(\d+)/))
          rotations[m[1].to_i] = m[2].to_i
        end
      end
      sizes.sort.map { |page, (w, h)| [ 90, 270 ].include?(rotations[page]) ? [ h, w ] : [ w, h ] }
    end

    def page_images(path, sizes)
      Dir.mktmpdir("anexo") do |dir|
        _out, _err, status = Open3.capture3("pdftoppm", "-r", DPI.to_s, "-jpeg", "-jpegopt", "quality=80", path.to_s, File.join(dir, "p"))
        return [] unless status.success?

        Dir.glob(File.join(dir, "p-*.jpg")).sort_by { |file| file[/-(\d+)\.jpg\z/, 1].to_i }.each_with_index.map do |file, index|
          width, height = sizes[index] || [ 595, 842 ]
          Page.new(jpeg: File.binread(file), width_pt: width, height_pt: height)
        end
      end
    end

    # Sem -layout: com -layout o pdftotext alinha colunas com espaços e quebra a ordem de leitura
    # dos parágrafos; aqui o que importa é o texto corrido.
    def pdf_text_pages(path)
      out, _err, status = Open3.capture3("pdftotext", "-enc", "UTF-8", path.to_s, "-")
      return [] unless status.success?

      repair_ligatures(out.dup.force_encoding(Encoding::UTF_8).scrub("")).split("\f")
    end

    # PDF gerado pelo SEI com Calibri (achado ao vivo, TR do IBAMA): a ligadura "ti" sai como
    # ESPAÇO no texto ("obje vo", "a vidade", "Jus ﬁcar") e "fi" sai como o caractere de ligadura.
    # Normaliza as ligaduras e devolve o "ti" quando o pedaço depois do espaço só existe como fim de
    # palavra depois de "ti" (vo, vidade, ca, ficar…). Não cobre tudo ("ti" no início da palavra se
    # perde) — por isso o consultor revisa o anexo no Word.
    LIGATURES = { "ﬁ" => "fi", "ﬂ" => "fl", "ﬀ" => "ff", "ﬃ" => "ffi", "ﬄ" => "ffl" }.freeze
    # Finais que só existem depois de "ti". "fica"/"ficar"/"ficado" são palavras de verdade
    # ("deverá ficar"), por isso só entram quando vierem com o caractere de ligadura "ﬁ" — o sinal
    # do defeito (medido: sem isso, um PDF normal ganhava "deverátificar").
    LOST_TI = /(?<=\p{L}) (vos?|vas?|vidades?|vamente|vel|veis|cas?|cos?|camente|dades?|mas?|mad[oa]s?|mativ[oa]s?|lizad[oa]s?|lização|lizações|lizar|liza|nuos?|nuidade|nuamente|tutos?|tucional|tucionais|cipação|cipações|cipar|cipa|ficação|ficações|ficativ[oa]s?)(?![\p{L}])/
    LOST_TI_FI = /(?<=\p{L}) (ﬁ(?:car|ca|cad[oa]s?|cando|cação|cações|cativ[oa]s?))(?![\p{L}])/

    def repair_ligatures(text)
      text.gsub(LOST_TI_FI) { "ti#{Regexp.last_match(1)}" }
        .gsub(Regexp.union(LIGATURES.keys), LIGATURES)
        .gsub(LOST_TI) { "ti#{Regexp.last_match(1)}" }
    end

    # Página com imagem de verdade (não ícone/logo pequeno) ganha a marcação de figura.
    def pages_with_figures(path)
      out, _err, status = Open3.capture3("pdfimages", "-list", path.to_s)
      return {} unless status.success?

      out.lines.drop(2).each_with_object({}) do |line, pages|
        cols = line.split
        page, width, height = cols[0].to_i, cols[3].to_i, cols[4].to_i
        pages[page] = true if width >= 300 && height >= 200
      end
    end

    def strip_repeated_lines(pages)
      return pages if pages.size < 3

      counts = Hash.new(0)
      pages.each { |page| page.lines.map(&:squish).uniq.each { |line| counts[line] += 1 if line.present? && line.length <= 120 } }
      threshold = [ (pages.size * BOILERPLATE_RATIO).ceil, 2 ].max
      repeated = counts.select { |_line, count| count >= threshold }.keys.to_set
      pages.map { |page| page.lines.reject { |line| repeated.include?(line.squish) }.join }
    end

    # Linhas em branco separam blocos; dentro de um bloco, linha que começa com marcador de lista
    # ou título numerado abre item novo. Hífen de fim de linha junta a palavra quebrada.
    def page_blocks(page)
      lines = merge_section_numbers(page.lines.map(&:strip).reject { |line| line.match?(PAGE_NUMBER) })
      chunks = lines.slice_when { |a, b| a.empty? || b.empty? }.map { |chunk| chunk.reject(&:empty?) }.reject(&:empty?)

      chunks.flat_map { |chunk| chunk_blocks(chunk) }
    end

    # Sumário ("OBJETIVO ........ 3") não serve no anexo: o Word não tem como reconstruir as páginas.
    TOC_LINE = /\.{5,}\s*\d*\z/
    TOC_TITLE = /\A(sum[áa]rio|[íi]ndice)\z/i
    SECTION_NUMBER = /\A\d{1,2}(\.\d{1,2}){0,3}\.?\z/

    # O pdftotext costuma separar o número do item do título ("4.1." numa linha, "Validade" na
    # outra, às vezes com linha em branco no meio). Junta de volta; número de sumário sai junto
    # com a linha do sumário.
    def merge_section_numbers(lines)
      result = []
      pending = nil
      lines.each do |line|
        next if line.match?(TOC_TITLE) && lines.any? { |other| other.match?(TOC_LINE) }

        if line.empty?
          result << line unless pending
        elsif line.match?(SECTION_NUMBER)
          pending = line
        elsif line.match?(TOC_LINE)
          pending = nil
        else
          result << (pending ? "#{pending} #{line}" : line)
          pending = nil
        end
      end
      result
    end

    def chunk_blocks(lines)
      groups = lines.slice_before { |line| line.match?(LIST_ITEM) || heading_line?(line) }
      groups.flat_map do |group|
        first = group.first
        if group.size == 1 && heading_line?(first)
          [ Block.of(:heading, first) ]
        elsif heading_line?(first) && group.size > 1
          [ Block.of(:heading, first), Block.of(:paragraph, join_lines(group.drop(1))) ]
        elsif first.match?(LIST_ITEM)
          [ Block.of(:list, join_lines(group).sub(LIST_ITEM, "")) ]
        else
          [ Block.of(:paragraph, join_lines(group)) ]
        end
      end
    end

    def heading_line?(line)
      return false if line.length > MAX_HEADING_LENGTH || line.end_with?(".", ";", ",", ":")

      letters = line.gsub(/[^[:alpha:]]/, "")
      line.match?(NUMBERED_HEADING) && line.split.size <= 14 || (letters.length >= 4 && letters == letters.upcase)
    end

    def join_lines(lines)
      lines.each_with_object(+"") do |line, text|
        if text.end_with?("-") && text[-2]&.match?(/[[:alpha:]]/)
          text.chop!
          text << line
        else
          text << " " unless text.empty?
          text << line
        end
      end.squish
    end
  end

  # Blocos → WordprocessingML (o título e as imagens são montados pelo ProposalDocxFiller, que
  # precisa do zip e das quebras de seção). Herda fonte/tamanho do corpo do modelo (Metropolis 11);
  # títulos em negrito; listas com o marcador "●" do modelo (numId 2, o mesmo das obrigações e do
  # SMS); tabelas simples com borda, largura da área de texto (8494 dxa, igual aos quadros do
  # modelo) e texto em 10 (regra de quadro do modelo).
  class Writer
    TABLE_WIDTH = 8494

    def initialize(blocks)
      @blocks = blocks
    end

    def call = Array(@blocks).map { |block| block_xml(block) }.join

    # Título do anexo: centralizado, negrito. outlineLvl 0 põe o anexo no painel de navegação do Word
    # sem entrar na numeração automática dos capítulos (não usa o estilo Título 1 do modelo).
    # page_break: false quando uma quebra de seção (página nova) já vem logo antes.
    def self.title_xml(title, page_break: true)
      writer = new([])
      ppr = %(#{"<w:pageBreakBefore/>" if page_break}<w:spacing w:after="240"/><w:jc w:val="center"/><w:outlineLvl w:val="0"/>)
      writer.send(:p_xml, ppr, writer.send(:run_xml, title, bold: true, size: 24))
    end

    private

    def block_xml(block)
      case block.kind
      when :heading then p_xml(%(<w:keepNext/><w:spacing w:before="240" w:after="120"/>), run_xml(block.text, bold: true))
      when :list then p_xml(%(<w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr><w:jc w:val="both"/>), run_xml(block.text))
      when :figure then p_xml(%(<w:jc w:val="center"/>), run_xml(block.text, italic: true))
      when :table then table_xml(block.rows)
      else p_xml(%(<w:jc w:val="both"/>), run_xml(block.text))
      end
    end

    def p_xml(ppr, runs)
      %(<w:p xmlns:w="#{W_NS}"><w:pPr>#{ppr}</w:pPr>#{runs}</w:p>)
    end

    def run_xml(text, bold: false, italic: false, size: nil)
      rpr = [ ("<w:b/>" if bold), ("<w:i/>" if italic), (%(<w:sz w:val="#{size}"/><w:szCs w:val="#{size}"/>) if size) ].compact.join
      %(<w:r>#{"<w:rPr>#{rpr}</w:rPr>" if rpr.present?}<w:t xml:space="preserve">#{escape(text)}</w:t></w:r>)
    end

    def table_xml(rows)
      columns = rows.map(&:size).max
      width = TABLE_WIDTH / columns
      border = %(w:val="single" w:sz="4" w:space="0" w:color="808080")
      borders = %w[top left bottom right insideH insideV].map { |side| "<w:#{side} #{border}/>" }.join
      grid = Array.new(columns) { %(<w:gridCol w:w="#{width}"/>) }.join
      body = rows.map do |cells|
        padded = cells + Array.new(columns - cells.size, "")
        cells_xml = padded.map do |cell|
          paragraphs = cell.to_s.split("\n").presence || [ "" ]
          content = paragraphs.map { |text| %(<w:p><w:pPr><w:spacing w:before="0" w:after="0"/></w:pPr>#{run_xml(text, size: 20)}</w:p>) }.join
          %(<w:tc><w:tcPr><w:tcW w:w="#{width}" w:type="dxa"/></w:tcPr>#{content}</w:tc>)
        end.join
        "<w:tr>#{cells_xml}</w:tr>"
      end.join
      %(<w:tbl xmlns:w="#{W_NS}"><w:tblPr><w:tblW w:w="#{TABLE_WIDTH}" w:type="dxa"/><w:tblBorders>#{borders}</w:tblBorders>) +
        %(<w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>#{grid}</w:tblGrid>#{body}</w:tbl>) +
        p_xml("", "") # parágrafo depois da tabela: o Word junta tabelas vizinhas sem ele
    end

    def escape(text)
      CGI.escapeHTML(text.to_s.gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/, ""))
    end
  end
end
