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

  # Tamanho de exibição fixo pro mapa da área de estudo (6 x 4,5 pol, proporção 4:3 — mesma
  # proporção pedida à Mapbox Static Images API, ver MapboxStaticMap::WIDTH/HEIGHT). EMU
  # (914400 = 1 polegada) não depende da dimensão real do arquivo de imagem: o Word escala
  # qualquer imagem pro cx/cy pedido, então não precisamos ler os pixels de verdade.
  IMAGE_WIDTH_EMU = 5486400
  IMAGE_HEIGHT_EMU = 4114800

  # A fronteira entre a parte técnica e a comercial é achada pelo TÍTULO da seção, nunca por
  # índice fixo de filho de <w:body>.
  #
  # Índice fixo foi exatamente o que quebrou em produção (proposta PT26011, agosto/2026): o
  # documento terminou no segundo item das obrigações da Papyrus, no meio da seção 7. O motivo é
  # que o texto da IA vira parágrafos de VERDADE antes do corte (ver expand_into_paragraphs!) —
  # um "escopo e metodologia" de 30 parágrafos deixa o corpo com dezenas de filhos a mais do que o
  # modelo tinha, e todo índice mapeado no modelo aponta para outro lugar. O corte então cai onde
  # calhar. Quanto mais a IA escreve, mais cedo o documento é cortado.
  #
  # Pelo título isso não acontece: o parágrafo do título continua sendo o mesmo nó, esteja ele na
  # posição que estiver.
  FIRST_TECHNICAL_HEADING = "APRESENTAÇÃO"
  FIRST_COMMERCIAL_HEADING = "PREÇO E CONDIÇÕES DE PAGAMENTO"

  # O estilo só DESEMPATA (para um parágrafo escrito pela IA que por acaso repita o texto de um
  # título não virar fronteira); quem identifica é o texto. O id do estilo não serve como
  # requisito porque muda sozinho quando alguém reabre e salva o modelo: o mesmo arquivo já veio
  # com "Ttulo1" (Word em português) e com "Heading1" depois de um salvamento.
  HEADING_STYLES = /\A(?:heading|t[íi]tulo|ttulo)\s*1\z/i

  def initialize(template_path)
    @template_path = template_path
  end

  # images: { "MAPA_AREA_ESTUDO" => bytes_png } — substitui o <w:r> do parágrafo que contém
  # literalmente "{{TOKEN}}" por uma imagem embutida de verdade (ver #fill_images!). Quem chama
  # decide se manda bytes aqui ou "" em `placeholders` pro mesmo token (nunca os dois).
  #
  # remove_paragraph_if_blank: tokens cujo parágrafo INTEIRO deve sumir (não só ficar com texto
  # vazio) quando o valor vier em branco — usado pra item de lista opcional (ex.: obrigação extra
  # da CONTRATANTE/PAPYRUS que só existe quando o ET pede algo específico): a maioria das
  # propostas não tem nenhuma, e um item de lista vazio ("● ") ficaria visível no documento final.
  def fill(placeholders:, tables: {}, images: {}, remove_paragraph_if_blank: [])
    build(placeholders: placeholders, tables: tables, images: images, remove_paragraph_if_blank: remove_paragraph_if_blank)
  end

  # technical_overrides/commercial_overrides: placeholders que diferem entre os dois arquivos
  # (ex.: título da capa) — mesclados por cima de `placeholders` só na respectiva variante. Quem
  # decide os valores é quem chama (ver GenerateProposalDocumentTool); este serviço não sabe o
  # que é "técnica" ou "comercial" no domínio, só que existem dois conjuntos de texto diferentes.
  def fill_split(placeholders:, tables: {}, images: {}, remove_paragraph_if_blank: [], technical_overrides: {}, commercial_overrides: {})
    {
      technical: build(placeholders: placeholders.merge(technical_overrides), tables: tables, images: images, remove_paragraph_if_blank: remove_paragraph_if_blank) { |doc| trim_body!(doc, keep: :technical) },
      commercial: build(placeholders: placeholders.merge(commercial_overrides), tables: tables, images: images, remove_paragraph_if_blank: remove_paragraph_if_blank) { |doc| trim_body!(doc, keep: :commercial) }
    }
  end

  private
    # Sempre opera numa cópia descartável — Zip::File#open com bloco reescreve o arquivo no
    # próprio caminho ao sair do bloco, então nunca toca no modelo original.
    def build(placeholders:, tables:, images: {}, remove_paragraph_if_blank: [])
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        FileUtils.cp(@template_path, tmp.path)

        Zip::File.open(tmp.path) do |zip|
          doc = Nokogiri::XML(zip.read("word/document.xml"))

          # Antes de fill_simple_placeholders!, pra achar o token "{{TOKEN}}" intacto no <w:t>.
          # Roda também pra variantes que depois são cortadas por trim_body! (ex.: comercial em
          # fill_split) — a seção some do documento final de qualquer forma, então a única sobra é
          # uma mídia/relationship sem uso no zip, inofensiva (Word/LibreOffice ignoram sem erro).
          fill_images!(doc, images, zip)
          fill_simple_placeholders!(doc, placeholders, remove_paragraph_if_blank: remove_paragraph_if_blank)
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

    # Separa as seções técnicas das comerciais. A capa e a carta de apresentação (tudo antes da
    # seção 1) ficam nos dois documentos. <w:sectPr> (margens/tamanho de página) sempre fica,
    # senão o documento resultante não abre.
    #
    # Roda DEPOIS de todo o preenchimento, sobre o corpo já com o texto da IA expandido — por isso
    # as fronteiras são recalculadas aqui, no corpo real, e não herdadas do modelo.
    def trim_body!(doc, keep:)
      body = doc.at_xpath("//w:body", NS)
      children = body.children.to_a

      technical_start = heading_index(children, FIRST_TECHNICAL_HEADING)
      commercial_start = heading_index(children, FIRST_COMMERCIAL_HEADING)
      section_range = keep == :technical ? (technical_start...commercial_start) : (commercial_start...children.size)
      keep_indices = (0...technical_start).to_a.concat(section_range.to_a).to_set

      children.each_with_index do |node, i|
        node.remove unless keep_indices.include?(i) || node.name == "sectPr"
      end
    end

    def heading_index(children, text)
      candidates = children.each_index.select do |i|
        children[i].name == "p" && children[i].xpath(".//w:t", NS).map(&:text).join.strip == text
      end
      # Sem a fronteira não dá pra separar técnica de comercial, e cortar por chute produziria
      # justamente o documento truncado que este método existe para evitar.
      raise "Título \"#{text}\" não encontrado no modelo — a separação técnica/comercial depende dele." if candidates.empty?

      candidates.find { |i| heading_style?(children[i]) } || candidates.first
    end

    def heading_style?(node)
      node.at_xpath(".//w:pPr/w:pStyle", NS)&.[]("w:val").to_s.match?(HEADING_STYLES)
    end
    # Troca o <w:r> do parágrafo que contém "{{TOKEN}}" por uma imagem embutida de verdade — 3
    # mudanças coordenadas no mesmo zip: arquivo novo em word/media/, relationship novo em
    # document.xml.rels, e um <w:drawing><wp:inline> no lugar do run (ver plano no topo do
    # arquivo). Token sem entrada em `images` simplesmente não é tocado aqui.
    def fill_images!(doc, images, zip)
      images.each do |token, bytes|
        next unless bytes

        text_node = doc.xpath("//w:t[contains(text(), '{{#{token}}}')]", NS).first
        run = text_node&.at_xpath("ancestor::w:r", NS)
        next unless run

        filename = "#{token.downcase}.png"
        rel_id = "rId_#{token}"
        zip.get_output_stream("word/media/#{filename}") { |f| f.write(bytes) }
        add_image_relationship!(zip, rel_id, filename)

        run.replace(Nokogiri::XML::DocumentFragment.parse(drawing_run_xml(rel_id, filename)))
      end
    end

    def add_image_relationship!(zip, rel_id, filename)
      rels_xml = zip.read("word/_rels/document.xml.rels")
      relationship = %(<Relationship Id="#{rel_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/#{filename}"/>)
      zip.get_output_stream("word/_rels/document.xml.rels") { |f| f.write(rels_xml.sub("</Relationships>", "#{relationship}</Relationships>")) }
    end

    # xmlns de w/wp/r/a/pic auto-declarados aqui pra ficar autossuficiente — o fragmento é
    # parseado fora do contexto do documento principal (sem herdar as declarações da raiz
    # <w:document>), então precisa carregar as próprias.
    def drawing_run_xml(rel_id, filename)
      <<~XML
        <w:r xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:rPr><w:noProof/></w:rPr><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="#{IMAGE_WIDTH_EMU}" cy="#{IMAGE_HEIGHT_EMU}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="9001" name="#{filename}"/><wp:cNvGraphicFramePr/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="0" name="#{filename}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="#{rel_id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="#{IMAGE_WIDTH_EMU}" cy="#{IMAGE_HEIGHT_EMU}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
      XML
    end

    def fill_simple_placeholders!(doc, values, remove_paragraph_if_blank: [])
      doc.xpath("//w:t", NS).each do |t|
        next unless t.text.include?("{{")

        tokens = t.text.scan(/\{\{(\w+)\}\}/).flatten
        replaced = t.text.gsub(/\{\{(\w+)\}\}/) { values.fetch(::Regexp.last_match(1), "{{#{::Regexp.last_match(1)}}}").to_s }

        if replaced.blank? && (tokens & remove_paragraph_if_blank).any?
          t.at_xpath("ancestor::w:p", NS)&.remove
        elsif replaced.include?("\n")
          expand_into_paragraphs!(t, replaced)
        else
          apply_line!(t, replaced)
        end
      end
    end

    # Um <w:t> com "\n" literal não vira parágrafo novo no Word — e uma linha terminada por
    # quebra manual nunca é justificada (jc="both" só estica linha que quebra sozinha por
    # largura). Texto da IA em vários parágrafos (separados por "\n\n") saía sempre alinhado à
    # esquerda por causa disso. Em vez de só trocar o texto, clonamos o <w:p> inteiro (preserva
    # pPr/jc/fonte) uma vez por linha, então cada parágrafo da IA vira um <w:p> de verdade.
    def expand_into_paragraphs!(t, replaced)
      paragraph = t.at_xpath("ancestor::w:p", NS)
      lines = replaced.split(/\n+/).map(&:strip).reject(&:empty?)
      return apply_line!(t, replaced) if paragraph.nil? || lines.size <= 1

      lines.each do |line|
        new_paragraph = paragraph.dup
        apply_line!(new_paragraph.at_xpath(".//w:t", NS), line)
        paragraph.add_previous_sibling(new_paragraph)
      end
      paragraph.remove
    end

    BOLD_LINE = /\A\*\*(.+)\*\*\z/

    # "**texto**" (mesma convenção Markdown que a IA já usa no chat) vira um parágrafo em negrito
    # — usado pelo escopo pra subtítulo numerado ("**5.1 MEIO FÍSICO**", ver
    # GenerateProposalDocumentTool#escopo_com_topicos). Resto do texto continua parágrafo comum,
    # sem precisar de um segundo placeholder/mecanismo só pra isso.
    def apply_line!(text_node, line)
      match = BOLD_LINE.match(line)
      return text_node.content = line unless match

      text_node.content = match[1]
      bold_run!(text_node)
    end

    def bold_run!(text_node)
      run = text_node.at_xpath("ancestor::w:r", NS)
      run_pr = run.at_xpath("w:rPr", NS)
      unless run_pr
        run_pr = Nokogiri::XML::Node.new("w:rPr", run.document)
        run.prepend_child(run_pr)
      end
      run_pr.add_child(Nokogiri::XML::Node.new("w:b", run.document)) unless run_pr.at_xpath("w:b", NS)
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

    # Célula com texto existente: reaproveita o run que tem o texto (mantém a formatação) e limpa
    # os demais.
    #
    # Um run PODE não ter <w:t> nenhum — é como o Word grava a célula vazia da linha-molde depois
    # que alguém reabre e salva o modelo (o run fica só com <w:rPr>). Assumir que o primeiro run
    # tinha texto quebrou a geração inteira quando o modelo voltou re-salvo: NoMethodError em
    # `content=` para nil, e o consultor via só "não consegui gerar o documento agora". Nesse caso
    # o run é aproveitado assim mesmo (é ele que carrega a fonte da célula) e ganha o nó de texto
    # que falta.
    def set_cell_text!(cell, text)
      runs = cell.xpath(".//w:r", NS)
      with_text = runs.find { |run| run.at_xpath(".//w:t", NS) }

      if with_text
        with_text.at_xpath(".//w:t", NS).content = text
        (runs.to_a - [ with_text ]).each { |r| r.at_xpath(".//w:t", NS)&.content = "" }
        return
      end

      return runs.first.add_child(text_node_for(cell.document, text)) if runs.any?

      # Célula sem run nenhum: cria um copiando o rPr do parágrafo, senão o texto entraria sem
      # fonte/tamanho definidos.
      paragraph = cell.at_xpath(".//w:p", NS)
      return unless paragraph

      run = Nokogiri::XML::Node.new("w:r", cell.document)
      rpr_template = paragraph.at_xpath(".//w:pPr/w:rPr", NS)
      run.add_child(rpr_template.dup) if rpr_template
      run.add_child(text_node_for(cell.document, text))
      paragraph.add_child(run)
    end

    def text_node_for(document, text)
      node = Nokogiri::XML::Node.new("w:t", document)
      node["xml:space"] = "preserve"
      node.content = text
      node
    end
end
