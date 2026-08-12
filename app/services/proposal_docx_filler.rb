# Preenche um modelo .docx real da Papyrus (marcadores {{TEXTO}} e tabelas com linhas variáveis)
# sem recriar o layout — abre o .docx como zip, edita só o word/document.xml via Nokogiri, e
# devolve os bytes do arquivo final. Ver CLAUDE.md seção 8.
#
# Uso:
#   filler = ProposalDocxFiller.new(template_path)
#   filler.fill(placeholders:, tables:)        # => bytes de 1 arquivo (documento único)
#   filler.fill_split(placeholders:, tables:)  # => { technical: bytes, commercial: bytes }
#
#   placeholders: { "NOME_CLIENTE" => "Acme S.A.", ... }
#   tables: {
#     1 => { rows: [ ["Produto", "1", "PDF"] ] },                      # sem numeração automática
#     3 => { rows: [ ["Descrição", "1.000,00"] ], auto_number: true }  # 1ª coluna = número da linha
#   }
class ProposalDocxFiller
  NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze

  # Índices dos filhos diretos de <w:body> no modelo atual (app/templates/docx/proposta_tecnica_
  # comercial.docx) — não são cálculo, foram mapeados inspecionando o XML do modelo. Se o modelo
  # for editado (parágrafo adicionado/removido antes da seção 10), esses números têm que ser
  # remapeados. 0..77 = capa + sumário de revisões + carta (compartilhado nos dois documentos);
  # 79..167 = seções 1 a 9 (técnica); 168.. = seção 10 em diante (comercial).
  SHARED_FRONT_MATTER = (0..77)
  TECHNICAL_SECTIONS = (79..167)
  COMMERCIAL_SECTIONS = (168..9999)

  def initialize(template_path)
    @template_path = template_path
  end

  def fill(placeholders:, tables: {})
    build(placeholders: placeholders, tables: tables)
  end

  def fill_split(placeholders:, tables: {})
    {
      technical: build(placeholders: placeholders, tables: tables) { |doc| trim_body!(doc, [ SHARED_FRONT_MATTER, TECHNICAL_SECTIONS ]) },
      commercial: build(placeholders: placeholders, tables: tables) { |doc| trim_body!(doc, [ SHARED_FRONT_MATTER, COMMERCIAL_SECTIONS ]) }
    }
  end

  private
    # Sempre opera numa cópia descartável — Zip::File#open com bloco reescreve o arquivo no
    # próprio caminho ao sair do bloco, então nunca toca no modelo original.
    def build(placeholders:, tables:)
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        FileUtils.cp(@template_path, tmp.path)

        Zip::File.open(tmp.path) do |zip|
          doc = Nokogiri::XML(zip.read("word/document.xml"))

          fill_simple_placeholders!(doc, placeholders)
          tables.each do |table_index, config|
            table_node = doc.xpath("//w:tbl", NS)[table_index]
            fill_table!(table_node, config.fetch(:rows), auto_number: config.fetch(:auto_number, false))
          end

          yield doc if block_given?
          zip.get_output_stream("word/document.xml") { |f| f.write(doc.to_xml) }
        end

        File.binread(tmp.path)
      end
    end

    # Remove os filhos de <w:body> fora das faixas de índice indicadas — usado pra separar as
    # seções técnicas das comerciais. <w:sectPr> (margens/tamanho de página) sempre fica, senão
    # o documento resultante não abre.
    def trim_body!(doc, keep_ranges)
      body = doc.at_xpath("//w:body", NS)
      keep_indices = keep_ranges.flat_map(&:to_a).to_set

      body.children.each_with_index do |node, i|
        node.remove unless keep_indices.include?(i) || node.name == "sectPr"
      end
    end
    def fill_simple_placeholders!(doc, values)
      doc.xpath("//w:t", NS).each do |t|
        next unless t.text.include?("{{")

        t.content = t.text.gsub(/\{\{(\w+)\}\}/) { values.fetch(::Regexp.last_match(1), "{{#{::Regexp.last_match(1)}}}").to_s }
      end
    end

    # tbl: nó <w:tbl>. A 2ª linha (1ª de dados) vira o "molde": clonada se faltar linha,
    # removida se sobrar. auto_number preenche a 1ª coluna com 1..N e desloca rows_data uma
    # coluna pra direita, então quem chama só passa as colunas de conteúdo de verdade.
    def fill_table!(tbl, rows_data, auto_number:)
      return unless tbl

      all_rows = tbl.xpath(".//w:tr", NS)
      template_row = all_rows[1]
      existing_data_rows = all_rows[1..]
      offset = auto_number ? 1 : 0

      rows_data.each_with_index do |row_values, i|
        row_node = existing_data_rows[i] || template_row.dup
        tbl.add_child(row_node) unless existing_data_rows[i]

        cells = row_node.xpath(".//w:tc", NS)
        set_cell_text!(cells[0], (i + 1).to_s) if auto_number

        row_values.each_with_index do |value, ci|
          cell = cells[ci + offset]
          next unless cell

          set_cell_text!(cell, value.to_s)
        end
      end

      existing_data_rows[rows_data.size..].to_a.each(&:remove) if rows_data.size < existing_data_rows.size
    end

    # Célula com texto existente: reaproveita o primeiro run (mantém a formatação) e limpa os
    # demais. Célula vazia (comum nas linhas-molde das tabelas): cria um run novo copiando o
    # rPr do parágrafo, senão o texto entraria sem fonte/tamanho definidos.
    def set_cell_text!(cell, text)
      runs = cell.xpath(".//w:r", NS)

      if runs.any?
        runs.first.at_xpath(".//w:t", NS).content = text
        runs[1..].to_a.each { |r| r.at_xpath(".//w:t", NS)&.content = "" }
        return
      end

      paragraph = cell.at_xpath(".//w:p", NS)
      return unless paragraph

      run = Nokogiri::XML::Node.new("w:r", cell.document)
      rpr_template = paragraph.at_xpath(".//w:pPr/w:rPr", NS)
      run.add_child(rpr_template.dup) if rpr_template

      text_node = Nokogiri::XML::Node.new("w:t", cell.document)
      text_node["xml:space"] = "preserve"
      text_node.content = text
      run.add_child(text_node)
      paragraph.add_child(run)
    end
end
