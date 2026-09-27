module Rag
  # Lê a planilha "irmã" de uma proposta (mesmo número no nome do arquivo) — a memória de
  # cálculo real daquele job: BDI, impostos, diárias, aluguel de carro, combustível, ARTs e
  # quem estava na equipe.
  #
  # Isso vira REFERÊNCIA HISTÓRICA consultável, nunca insumo do motor de precificação
  # (CLAUDE.md seção 5: preço é sempre calculado em Ruby, a partir do que o consultor
  # confirma na Tela de Precificação — nunca copiado de uma proposta antiga).
  #
  # XLSX/XLSM é zip com XML dentro, igual ao DOCX e ao KMZ, então sai com o rubyzip que já é
  # dependência do projeto — sem gem nova só para ler algumas células.
  class PricingSheetReader
    MAX_ROWS_PER_SHEET = 400

    Sheet = Data.define(:name, :rows)
    Result = Data.define(:sheets, :row_count) do
      # Texto achatado da planilha, para virar um chunk buscável junto com o documento.
      def to_text
        sheets.map do |sheet|
          rows = sheet.rows.map { |row| row.join(" | ") }.join("\n")
          "## Planilha: #{sheet.name}\n#{rows}"
        end.join("\n\n")
      end
    end

    def initialize(path)
      @path = path
    end

    def call
      Zip::File.open(@path) do |zip|
        shared = shared_strings(zip)
        names = sheet_names(zip)
        sheets = sheet_entries(zip).filter_map { |entry| read_sheet(entry, shared, names) }

        Result.new(sheets: sheets, row_count: sheets.sum { |s| s.rows.length })
      end
    rescue Zip::Error, Errno::ENOENT => e
      Rails.logger.warn("[Rag::PricingSheetReader] falhou em #{@path}: #{e.message}")
      Result.new(sheets: [], row_count: 0)
    end

    private

    # Strings do XLSX ficam num dicionário compartilhado; as células só guardam o índice.
    def shared_strings(zip)
      entry = zip.find_entry("xl/sharedStrings.xml")
      return [] unless entry

      xml = Nokogiri::XML(entry.get_input_stream.read)
      xml.remove_namespaces!
      xml.xpath("//si").map { |si| si.xpath(".//t").map(&:text).join }
    end

    def sheet_entries(zip)
      zip.glob("xl/worksheets/sheet*.xml").sort_by { |entry| entry.name[/\d+/].to_i }
    end

    # Nome real de cada aba ("Orçamento", "Quantitativos"): workbook.xml lista as abas com um r:id,
    # e workbook.xml.rels diz qual arquivo sheetN.xml é cada r:id. Sem isso, "sheet3".
    def sheet_names(zip)
      workbook = zip.find_entry("xl/workbook.xml")
      rels = zip.find_entry("xl/_rels/workbook.xml.rels")
      return {} unless workbook && rels

      targets = Nokogiri::XML(rels.get_input_stream.read).tap(&:remove_namespaces!)
        .xpath("//Relationship").to_h { |rel| [ rel["Id"], File.basename(rel["Target"].to_s) ] }
      Nokogiri::XML(workbook.get_input_stream.read).tap(&:remove_namespaces!)
        .xpath("//sheet").to_h { |sheet| [ targets[sheet["id"]], sheet["name"] ] }.compact
    end

    def read_sheet(entry, shared, names = {})
      xml = Nokogiri::XML(entry.get_input_stream.read)
      xml.remove_namespaces!

      rows = xml.xpath("//row").first(MAX_ROWS_PER_SHEET).filter_map do |row|
        cells = row_cells(row, shared)
        next if cells.all?(&:blank?)

        cells
      end
      return nil if rows.empty?

      Sheet.new(name: names[File.basename(entry.name)] || entry.name[%r{sheet\d+}], rows: rows)
    end

    # Célula vazia não existe no XML — a próxima célula preenchida diz a própria coluna ("C7").
    # Sem respeitar isso, uma linha com a coluna B vazia jogava o valor de C para debaixo de B.
    def row_cells(row, shared)
      cells = []
      row.xpath("./c").each do |cell|
        index = column_index(cell["r"]) || cells.length
        cells[index] = cell_value(cell, shared).to_s
      end
      cells.map(&:to_s)
    end

    def column_index(reference)
      letters = reference.to_s[/\A[A-Z]+/]
      return nil unless letters

      letters.chars.reduce(0) { |acc, char| (acc * 26) + (char.ord - 64) } - 1
    end

    def cell_value(cell, shared)
      value = cell.at_xpath("./v")&.text
      return cell.at_xpath(".//t")&.text.to_s if cell["t"] == "inlineStr"
      return "" if value.blank?

      cell["t"] == "s" ? shared[value.to_i].to_s : value
    end
  end
end
