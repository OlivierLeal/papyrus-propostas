require "zip"

module Spreadsheets
  # Lê e escreve planilhas .xlsx/.xlsm do CLIENTE (PPU, DFP etc.) mexendo só nas células que o
  # licitante preenche — mesma filosofia do .docx (CLAUDE.md seção 8): o arquivo do cliente é a
  # fonte do layout, o código só troca conteúdo. É zip com XML dentro; tudo que não for a aba
  # editada, o workbook.xml ou o sharedStrings passa byte a byte (macros do .xlsm incluídas).
  #
  # Escrita:
  # - número em <v>; texto como inlineStr (não mexe no sharedStrings, que outras células usam);
  # - nunca escreve por cima de fórmula (o total da planilha é do cliente);
  # - linhas de tabela novas são cópias da linha-modelo, com as fórmulas traduzidas pra linha nova;
  # - tira o valor em cache de TODA fórmula e liga fullCalcOnLoad: quem abrir (Excel/LibreOffice)
  #   recalcula com os valores novos, em vez de mostrar o total antigo.
  class Workbook
    NS = { "m" => "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
           "r" => "http://schemas.openxmlformats.org/officeDocument/2006/relationships" }.freeze
    REL_NS = { "rel" => "http://schemas.openxmlformats.org/package/2006/relationships" }.freeze

    Sheet = Data.define(:name, :path, :state)
    Cell = Data.define(:ref, :value, :formula)

    class Error < StandardError; end

    def self.open(bytes) = new(bytes)

    def initialize(bytes)
      @entries = {}
      Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
        zip.each { |entry| @entries[entry.name] = entry.get_input_stream.read unless entry.directory? }
      end
      raise Error, "não é uma planilha .xlsx/.xlsm" unless @entries.key?("xl/workbook.xml")

      @docs = {}
    end

    def sheets
      @sheets ||= begin
        rels = Nokogiri::XML(@entries["xl/_rels/workbook.xml.rels"])
        targets = rels.xpath("//rel:Relationship", REL_NS).to_h { |rel| [ rel["Id"], rel["Target"] ] }
        workbook.xpath("//m:sheets/m:sheet", NS).map do |node|
          target = targets.fetch(node["r:id"] || node.attribute_with_ns("id", NS["r"])&.value)
          path = target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
          Sheet.new(node["name"], path, node["state"] || "visible")
        end
      end
    end

    def sheet(name)
      sheets.find { |s| s.name == name } || sheets.find { |s| s.name.casecmp?(name.to_s.strip) } ||
        raise(Error, "aba \"#{name}\" não existe")
    end

    # Células não vazias da aba (texto, número ou fórmula), na ordem do arquivo.
    def cells(sheet_name)
      doc(sheet(sheet_name).path).xpath("//m:sheetData/m:row/m:c", NS).filter_map do |c|
        formula = c.at_xpath("m:f", NS)
        text = formula_text(c) if formula
        value = cell_value(c)
        next if text.nil? && value.nil?

        Cell.new(c["r"], value, text)
      end
    end

    def value(sheet_name, ref)
      c = cell_node(sheet_name, ref, create: false)
      c && cell_value(c)
    end

    def formula?(sheet_name, ref)
      c = cell_node(sheet_name, ref, create: false)
      !!c&.at_xpath("m:f", NS)
    end

    # Texto das abas pra IA entender a planilha: endereço, valor ou fórmula de cada célula. Com
    # `computed` (a mesma planilha recalculada, ver Recalculator), a fórmula vem com o resultado —
    # é o que a IA vê na rodada de correção. `only` limita às abas citadas.
    def to_prompt_text(max_cells_per_sheet: 350, max_value_length: 160, computed: nil, only: nil)
      sheets.filter_map do |s|
        next if only && only.none? { |name| name.to_s.casecmp?(s.name) }

        lines = cells(s.name).first(max_cells_per_sheet).map do |cell|
          content = cell.formula ? "=#{cell.formula}" : cell.value.to_s.gsub(/\s+/, " ")
          content = content.truncate(max_value_length)
          if cell.formula && computed
            result = computed.value(s.name, cell.ref)
            content += " → #{result.is_a?(Float) ? result.round(4) : result}"
          end
          "#{cell.ref}: #{content}"
        end
        header = "### Aba \"#{s.name}\"#{" (oculta)" unless s.state == "visible"}"
        [ header, *lines ].join("\n")
      end.join("\n\n")
    end

    def write(sheet_name, ref, value)
      c = cell_node(sheet_name, ref, create: true)
      raise Error, "#{sheet_name}!#{ref} tem fórmula — não escrevo por cima" if c.at_xpath("m:f", NS)

      c.children.each(&:remove)
      c.remove_attribute("t")
      if value.is_a?(Numeric)
        c.add_child(node(c.document, "v", format_number(value)))
      else
        c["t"] = "inlineStr"
        is = node(c.document, "is")
        t = node(c.document, "t", value.to_s)
        t["xml:space"] = "preserve"
        is.add_child(t)
        c.add_child(is)
      end
      touch(sheet(sheet_name).path)
    end

    # Replica a linha-modelo pra baixo: a linha i da tabela é template_row + i. Colunas com fórmula
    # na linha-modelo ganham a fórmula traduzida nas linhas novas; `values` escreve o resto.
    def fill_table(sheet_name, template_row, rows)
      path = sheet(sheet_name).path
      template = row_node(path, template_row, create: false) or raise(Error, "#{sheet_name}: linha-modelo #{template_row} não existe")
      template_cells = template.xpath("m:c", NS).map { |c| [ column_of(c["r"]), c ] }

      rows.each_with_index do |values, index|
        row_number = template_row + index
        unless index.zero?
          template_cells.each do |column, source|
            target = cell_node(sheet_name, "#{column}#{row_number}", create: true)
            target["s"] = source["s"] if source["s"] && !target["s"]
            formula = formula_text(source)
            next unless formula && !target.at_xpath("m:f", NS)

            target.children.each(&:remove)
            target.remove_attribute("t")
            target.add_child(node(target.document, "f", shift_rows(formula, index)))
          end
        end
        values.each { |column, value| write(sheet_name, "#{column}#{row_number}", value) }
      end
      touch(path)
    end

    def unhide(sheet_name)
      node = workbook.xpath("//m:sheets/m:sheet", NS).find { |n| n["name"] == sheet(sheet_name).name }
      node&.remove_attribute("state")
      @sheets = nil
      touch("xl/workbook.xml")
    end

    def to_bytes
      force_recalculation!
      buffer = Zip::OutputStream.write_buffer do |out|
        @entries.each do |name, bytes|
          out.put_next_entry(name)
          out.write(@docs.key?(name) ? @docs[name].to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML) : bytes)
        end
      end
      buffer.string
    end

    private

    def workbook = doc("xl/workbook.xml")

    def doc(path)
      @docs[path] ||= Nokogiri::XML(@entries.fetch(path))
    end

    def touch(path) = doc(path)

    def shared_strings
      @shared_strings ||= if (xml = @entries["xl/sharedStrings.xml"])
        Nokogiri::XML(xml).xpath("//m:si", NS).map { |si| si.xpath(".//m:t", NS).map(&:text).join }
      else
        []
      end
    end

    def cell_value(c)
      case c["t"]
      when "s" then shared_strings[c.at_xpath("m:v", NS)&.text.to_i]
      when "inlineStr" then c.xpath(".//m:t", NS).map(&:text).join.presence
      when "str", "e" then c.at_xpath("m:v", NS)&.text
      when "b" then c.at_xpath("m:v", NS)&.text == "1"
      else
        raw = c.at_xpath("m:v", NS)&.text
        raw && (raw.include?(".") || raw.include?("E") ? raw.to_f : raw.to_i)
      end
    end

    # Fórmula compartilhada (<f t="shared" si="0"/> sem texto) é resolvida a partir da célula-mestre.
    def formula_text(c)
      f = c.at_xpath("m:f", NS)
      return nil unless f
      return f.text if f.text.present?
      return nil unless f["t"] == "shared"

      master = c.document.xpath("//m:c/m:f[@t='shared'][@si='#{f['si']}']", NS).find { |m| m.text.present? }
      return nil unless master

      shift_rows(master.text, row_of(c["r"]) - row_of(master.parent["r"]))
    end

    # Desloca as referências RELATIVAS de linha (A7 → A8); $A$7, colunas inteiras (N:N) e texto
    # entre aspas ficam.
    def shift_rows(formula, delta)
      return formula if delta.zero?

      formula.split(/("[^"]*")/).map do |part|
        next part if part.start_with?('"')

        part.gsub(/(?<![A-Za-z_\d$])(\$?[A-Z]{1,3})(\$?)(\d+)(?![\d(])/) do
          column, anchor, row = Regexp.last_match.captures
          anchor == "$" ? "#{column}$#{row}" : "#{column}#{row.to_i + delta}"
        end
      end.join
    end

    def row_node(path, number, create:)
      data = doc(path).at_xpath("//m:sheetData", NS)
      found = data.at_xpath("m:row[@r='#{number}']", NS)
      return found if found || !create

      row = node(data.document, "row")
      row["r"] = number.to_s
      following = data.xpath("m:row", NS).find { |r| r["r"].to_i > number }
      following ? following.add_previous_sibling(row) : data.add_child(row)
      row
    end

    def cell_node(sheet_name, ref, create:)
      ref = ref.to_s.upcase.delete("$")
      raise Error, "célula inválida: #{ref}" unless ref.match?(/\A[A-Z]{1,3}\d+\z/)

      row = row_node(sheet(sheet_name).path, row_of(ref), create: create)
      return nil unless row

      found = row.at_xpath("m:c[@r='#{ref}']", NS)
      return found if found || !create

      c = node(row.document, "c")
      c["r"] = ref
      following = row.xpath("m:c", NS).find { |other| column_index(column_of(other["r"])) > column_index(column_of(ref)) }
      following ? following.add_previous_sibling(c) : row.add_child(c)
      c
    end

    def force_recalculation!
      @entries.each_key do |name|
        next unless name.start_with?("xl/worksheets/") && name.end_with?(".xml")

        d = doc(name)
        d.xpath("//m:c[m:f]", NS).each do |c|
          c.at_xpath("m:v", NS)&.remove
          c.remove_attribute("t") if %w[str e b n].include?(c["t"])
        end
      end
      calc = workbook.at_xpath("//m:calcPr", NS)
      unless calc
        calc = node(workbook, "calcPr")
        workbook.root.add_child(calc)
      end
      calc["fullCalcOnLoad"] = "1"
      @entries.delete("xl/calcChain.xml") # cadeia de cálculo antiga não vale mais; o Excel refaz
      if @entries.key?("[Content_Types].xml")
        doc("[Content_Types].xml").xpath("//*[@PartName='/xl/calcChain.xml']").each(&:remove)
      end
      doc("xl/_rels/workbook.xml.rels").xpath("//rel:Relationship[contains(@Target, 'calcChain')]", REL_NS).each(&:remove)
    end

    def node(document, name, text = nil)
      n = Nokogiri::XML::Node.new(name, document)
      n.namespace = document.root.namespace
      n.content = text if text
      n
    end

    def format_number(value)
      value = value.to_d if value.is_a?(Rational)
      value.is_a?(Integer) ? value.to_s : value.to_d.round(10).to_s("F").sub(/\.0\z/, "")
    end

    def row_of(ref) = ref[/\d+/].to_i
    def column_of(ref) = ref[/[A-Z]+/]

    def column_index(letters)
      letters.each_char.reduce(0) { |sum, ch| sum * 26 + (ch.ord - 64) }
    end
  end
end
