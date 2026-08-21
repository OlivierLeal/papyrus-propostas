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
        sheets = sheet_entries(zip).filter_map { |entry| read_sheet(entry, shared) }

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
      zip.glob("xl/worksheets/sheet*.xml").sort_by(&:name)
    end

    def read_sheet(entry, shared)
      xml = Nokogiri::XML(entry.get_input_stream.read)
      xml.remove_namespaces!

      rows = xml.xpath("//row").first(MAX_ROWS_PER_SHEET).filter_map do |row|
        cells = row.xpath("./c").map { |cell| cell_value(cell, shared) }
        cells = cells.map(&:to_s)
        next if cells.all?(&:blank?)

        cells
      end
      return nil if rows.empty?

      Sheet.new(name: entry.name[%r{sheet\d+}], rows: rows)
    end

    def cell_value(cell, shared)
      value = cell.at_xpath("./v")&.text
      return cell.at_xpath(".//t")&.text.to_s if cell["t"] == "inlineStr"
      return "" if value.blank?

      cell["t"] == "s" ? shared[value.to_i].to_s : value
    end
  end
end
