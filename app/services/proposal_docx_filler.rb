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

  # Levantado por #insert_schedule_section quando o .docx enviado não tem onde ancorar o
  # cronograma (nenhuma seção "PRAZO DE EXECUÇÃO"). A ferramenta traduz isso numa mensagem de chat.
  class SectionAnchorError < StandardError; end

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
  # schedules: { "servico" => { start_date:, items: [ScheduleItem,...] }, "implantacao" => {...} }
  # — insere uma página paisagem com a(s) tabela(s) de cronograma logo depois do prazo de execução
  # (ver #insert_schedule_tables!). Só as chaves presentes viram seção no documento; sem nenhuma,
  # o documento sai igual a antes desta funcionalidade existir.
  #
  # remove_paragraph_if_blank: tokens cujo parágrafo INTEIRO deve sumir (não só ficar com texto
  # vazio) quando o valor vier em branco — usado pra item de lista opcional (ex.: obrigação extra
  # da CONTRATANTE/PAPYRUS que só existe quando o ET pede algo específico): a maioria das
  # propostas não tem nenhuma, e um item de lista vazio ("● ") ficaria visível no documento final.
  def fill(placeholders:, tables: {}, images: {}, schedules: {}, remove_paragraph_if_blank: [])
    build(placeholders: placeholders, tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank)
  end

  # technical_overrides/commercial_overrides: placeholders que diferem entre os dois arquivos
  # (ex.: título da capa) — mesclados por cima de `placeholders` só na respectiva variante. Quem
  # decide os valores é quem chama (ver GenerateProposalDocumentTool); este serviço não sabe o
  # que é "técnica" ou "comercial" no domínio, só que existem dois conjuntos de texto diferentes.
  def fill_split(placeholders:, tables: {}, images: {}, schedules: {}, remove_paragraph_if_blank: [], technical_overrides: {}, commercial_overrides: {})
    {
      technical: build(placeholders: placeholders.merge(technical_overrides), tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank) { |doc| trim_body!(doc, keep: :technical) },
      commercial: build(placeholders: placeholders.merge(commercial_overrides), tables: tables, images: images, schedules: schedules, remove_paragraph_if_blank: remove_paragraph_if_blank) { |doc| trim_body!(doc, keep: :commercial) }
    }
  end

  # Insere (ou substitui) SÓ a seção paisagem de cronograma — tabela Quadro 9-N + infográfico —
  # num .docx JÁ FINALIZADO que veio de fora: o consultor gerou a proposta pelo sistema, revisou
  # no Word por fora, e quer só o cronograma de volta. Diferente de #fill/#fill_split, que montam
  # o documento inteiro a partir do modelo — aqui o documento do consultor É a base e a única
  # mudança é o bloco de cronograma, ancorado pelo título "PRAZO DE EXECUÇÃO" (o token
  # {{PRAZO_EXECUCAO}} não existe mais num .docx finalizado). `schedules` no mesmo formato de #fill.
  # `template_path` não é usado neste caminho — pode instanciar com nil.
  def insert_schedule_section(docx_bytes, schedules:)
    return docx_bytes if schedules.blank?

    Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
      File.binwrite(tmp.path, docx_bytes)

      Zip::File.open(tmp.path) do |zip|
        document_xml = zip.read("word/document.xml")
        doc = Nokogiri::XML(document_xml)
        ensure_png_content_type!(zip)
        sect_props = sect_props_from_xml(document_xml, zip.read("word/_rels/document.xml.rels"))
        insert_or_replace_schedule_block!(doc, schedules, zip, sect_props)
        zip.get_output_stream("word/document.xml") { |f| f.write(doc.to_xml) }
      end

      File.binread(tmp.path)
    end
  end

  private
    # Sempre opera numa cópia descartável — Zip::File#open com bloco reescreve o arquivo no
    # próprio caminho ao sair do bloco, então nunca toca no modelo original.
    def build(placeholders:, tables:, images: {}, schedules: {}, remove_paragraph_if_blank: [])
      Tempfile.create([ "proposal", ".docx" ], binmode: true) do |tmp|
        FileUtils.cp(@template_path, tmp.path)

        Zip::File.open(tmp.path) do |zip|
          doc = Nokogiri::XML(zip.read("word/document.xml"))

          # Antes de fill_simple_placeholders!, pra achar o token "{{TOKEN}}" intacto no <w:t>.
          # Roda também pra variantes que depois são cortadas por trim_body! (ex.: comercial em
          # fill_split) — a seção some do documento final de qualquer forma, então a única sobra é
          # uma mídia/relationship sem uso no zip, inofensiva (Word/LibreOffice ignoram sem erro).
          fill_images!(doc, images, zip)

          # tables.each ANTES de insert_schedule_tables! — os índices em `tables` são a POSIÇÃO da
          # tabela no corpo (ver build_tables no chamador). Minha tabela de cronograma nasce ENTRE
          # a tabela 2 (equipe) e a 3 (preço) — inseri-la antes deslocaria "//w:tbl"[3] pra apontar
          # pra ela em vez do Preço, e fill_table! reescreveria o cronograma por cima. Preencher as
          # tabelas originais primeiro resolve os índices antes de qualquer tabela nova existir,
          # então a ordem de inserção deixa de importar.
          tables.each do |table_index, config|
            table_node = doc.xpath("//w:tbl", NS)[table_index]
            if table_index == 0
              fill_revisions_table!(table_node, config.fetch(:rows))
            else
              fill_table!(table_node, config.fetch(:rows), auto_number: config.fetch(:auto_number, false))
            end
          end
          insert_schedule_tables!(doc, schedules, zip)
          fill_simple_placeholders!(doc, placeholders, remove_paragraph_if_blank: remove_paragraph_if_blank)

          # O bloco de assinatura técnico (ver TECHNICAL_SIGNATURE_*) só faz sentido separado do
          # comercial quando o documento REALMENTE sai em dois arquivos (fill_split, com bloco —
          # trim_body! mantém só o pedaço certo em cada um). Sem split (fill, documento único),
          # os dois blocos (esse + o original no fim do corpo) sobreviveriam juntos no mesmo
          # arquivo — o cliente veria a assinatura duas vezes, achado ao vivo gerando o combinado.
          if block_given?
            yield doc
          else
            remove_technical_signature_duplicate!(doc)
          end
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

    # Bloco de assinatura duplicado no modelo (Papyrus + cliente, em negrito) logo depois de
    # "VALIDADE DA PROPOSTA" — pra a proposta TÉCNICA (arquivo separado, ou o único gerado
    # enquanto a proposta ainda é draft) também terminar com assinatura, e não só a comercial
    # (que já tinha o bloco original no fim do corpo, ver CLAUDE.md seção 8). Âncora por texto,
    # nunca por índice — mesma regra de FIRST_TECHNICAL_HEADING/FIRST_COMMERCIAL_HEADING.
    TECHNICAL_SIGNATURE_ANCHOR = "Data do aceite da proposta:"

    # Sem split (fill, documento único), os dois blocos de assinatura — este e o original no fim
    # do corpo — sobreviveriam juntos no mesmo arquivo, e o cliente veria a assinatura duas
    # vezes. Só faz sentido manter os dois quando trim_body! vai cortar o documento em dois
    # arquivos de verdade (fill_split): cada um fica só com o bloco do seu próprio lado.
    def remove_technical_signature_duplicate!(doc)
      body = doc.at_xpath("//w:body", NS)
      children = body.children.to_a

      accept_index = children.each_index.find do |i|
        children[i].name == "p" && children[i].xpath(".//w:t", NS).map(&:text).join.include?(TECHNICAL_SIGNATURE_ANCHOR)
      end
      return unless accept_index

      commercial_index = heading_index(children, FIRST_COMMERCIAL_HEADING)
      children[(accept_index + 1)...commercial_index].each(&:remove)
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
        write_image!(zip, rel_id, filename, bytes)

        run.replace(Nokogiri::XML::DocumentFragment.parse(drawing_run_xml(rel_id, filename, IMAGE_WIDTH_EMU, IMAGE_HEIGHT_EMU)))
      end
    end

    # Grava a mídia em word/media/ e registra o relationship — extraído de fill_images! pra
    # servir também o infográfico do cronograma (insert_schedule_tables!), que não substitui
    # token nenhum (o desenho nasce do zero, não existe {{TOKEN}} pra ele no modelo).
    def write_image!(zip, rel_id, filename, bytes)
      zip.get_output_stream("word/media/#{filename}") { |f| f.write(bytes) }
      add_image_relationship!(zip, rel_id, filename)
    end

    def add_image_relationship!(zip, rel_id, filename)
      rels_xml = zip.read("word/_rels/document.xml.rels")
      relationship = %(<Relationship Id="#{rel_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/#{filename}"/>)
      zip.get_output_stream("word/_rels/document.xml.rels") { |f| f.write(rels_xml.sub("</Relationships>", "#{relationship}</Relationships>")) }
    end

    # xmlns de w/wp/r/a/pic auto-declarados aqui pra ficar autossuficiente — o fragmento é
    # parseado fora do contexto do documento principal (sem herdar as declarações da raiz
    # <w:document>), então precisa carregar as próprias. cx/cy em EMU por chamada (não fixo) —
    # o mapa da área de estudo sempre usa a mesma proporção 4:3 (IMAGE_WIDTH_EMU/IMAGE_HEIGHT_EMU),
    # mas o infográfico do cronograma varia de altura conforme o número de linhas de círculos.
    def drawing_run_xml(rel_id, filename, width_emu, height_emu)
      <<~XML
        <w:r xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:rPr><w:noProof/></w:rPr><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="#{width_emu}" cy="#{height_emu}"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="9001" name="#{filename}"/><wp:cNvGraphicFramePr/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="0" name="#{filename}"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="#{rel_id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="#{width_emu}" cy="#{height_emu}"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
      XML
    end

    # "PRAZO DE EXECUÇÃO" é sempre a 11ª seção de nível 1 do modelo (estrutura fixa — mesmo
    # princípio de GenerateProposalDocumentTool::SECAO_ESCOPO_NUMERO), por isso dá pra numerar o
    # quadro aqui, sem a IA saber a posição real do documento renderizado. Era a 9ª até 2026-09
    # ("ITENS NÃO PREVISTOS" virou capítulo independente, seção 7), depois a 10ª até o capítulo
    # fixo "EXIGÊNCIAS SMS" (seção 10) entrar logo depois de EQUIPE TÉCNICA, também em 2026-09.
    SECAO_PRAZO_NUMERO = 11

    SCHEDULE_TYPES_IN_ORDER = %w[servico implantacao].freeze
    SCHEDULE_CAPTIONS = {
      "servico" => "Cronograma do Serviço.",
      "implantacao" => "Cronograma de Implantação do Empreendimento."
    }.freeze
    SCHEDULE_UNITS = { "servico" => :week, "implantacao" => :month }.freeze

    # Propriedades de seção (cabeçalho/rodapé/margens). O rodapé do modelo (`footer1.xml`, rId16)
    # tem os text boxes "www…"/"Sistema de Gestão…" ancorados e dimensionados pra coluna RETRATO —
    # numa página paisagem eles saem deslocados pra esquerda ("torto", relato do consultor no chat
    # 32). `footer2.xml` (rId20) é a cópia com esses offsets recentralizados pra coluna paisagem
    # (mesma mecânica de `header2.xml` da página 1). Só a variante PAISAGEM usa rId20; o retrato
    # (que não tem esse problema) fica no rId16 de sempre.
    HEADER_REF_XML = '<w:headerReference w:type="default" r:id="rId15"/>'
    SECT_HEADER_FOOTER_XML = "#{HEADER_REF_XML}<w:footerReference w:type=\"default\" r:id=\"rId16\"/>"
    LANDSCAPE_HEADER_FOOTER_XML = "#{HEADER_REF_XML}<w:footerReference w:type=\"default\" r:id=\"rId20\"/>"
    PORTRAIT_SECT_XML = "#{SECT_HEADER_FOOTER_XML}<w:pgSz w:w=\"11906\" w:h=\"16838\"/>" \
      '<w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/>'
    LANDSCAPE_SECT_XML = "#{LANDSCAPE_HEADER_FOOTER_XML}<w:pgSz w:orient=\"landscape\" w:w=\"16838\" w:h=\"11906\"/>" \
      '<w:pgMar w:top="1701" w:right="1418" w:bottom="1701" w:left="1418" w:header="708" w:footer="708" w:gutter="0"/>'

    # Insere a(s) tabela(s) de cronograma numa página PAISAGEM logo depois do prazo de execução —
    # ver CLAUDE.md seção 8 e ScheduleTableBuilder. Âncora pelo token "{{PRAZO_EXECUCAO}}" (ainda
    # intacto nesse ponto — roda antes de fill_simple_placeholders!, mesmo motivo de
    # fill_images!), nunca por índice de filho de <w:body> — mesma regra de trim_body!.
    #
    # Mecânica de seção OOXML: um parágrafo com <w:sectPr> fecha a seção que TERMINA nele (não a
    # que começa depois). Bastam 2 parágrafos novos — um retrato (fecha a seção 1, tudo que já
    # existia, sem mudar nada nela) e um paisagem (fecha a seção 2, as tabelas) — o resto do
    # documento (VALIDADE DA PROPOSTA em diante, até o bloco de assinatura) volta pro retrato
    # sozinho, herdando do <w:sectPr> final que já existe no corpo (seção 3, implícita).
    def insert_schedule_tables!(doc, schedules, zip)
      return if schedules.blank?

      xml = schedule_block_xml(schedules, zip)
      return if xml.blank?

      anchor = doc.xpath("//w:t[contains(text(), '{{PRAZO_EXECUCAO}}')]", NS).first
      paragraph = anchor&.at_xpath("ancestor::w:p", NS)
      return unless paragraph

      paragraph.add_next_sibling(Nokogiri::XML::DocumentFragment.parse(xml))
    end

    # portrait_sect/landscape_sect: propriedades de seção pra abrir/fechar o bloco paisagem. No
    # caminho do modelo (#build → #insert_schedule_tables!) são as constantes de sempre; em
    # #insert_schedule_section vêm do próprio .docx do consultor (que pode ter cabeçalho/rodapé
    # com r:id diferente se passou por "Salvar como" no Word).
    def schedule_block_xml(schedules, zip, portrait_sect: PORTRAIT_SECT_XML, landscape_sect: LANDSCAPE_SECT_XML)
      quadro_number = 0
      tables_xml = +""

      SCHEDULE_TYPES_IN_ORDER.each do |type|
        payload = schedules[type]
        next unless payload

        quadro_number += 1
        tables_xml << schedule_timeline_xml(type, payload, zip)
        tables_xml << schedule_caption_xml("Quadro #{SECAO_PRAZO_NUMERO}-#{quadro_number}: #{SCHEDULE_CAPTIONS.fetch(type)}")
        tables_xml << ScheduleTableBuilder.new(payload[:items], start_date: payload[:start_date], unit: SCHEDULE_UNITS.fetch(type)).build_xml
      end

      return "" if tables_xml.blank?

      "#{section_break_paragraph_xml(portrait_sect)}#{tables_xml}#{section_break_paragraph_xml(landscape_sect)}"
    end

    SCHEDULE_ANCHOR_HEADING = "PRAZO DE EXECU" # começo do título da seção 9, sem depender do acento/final

    # Margens do bloco paisagem (mesmas do LANDSCAPE_SECT_XML) — separadas pra reusar quando as
    # props de seção vêm do .docx do consultor em #insert_schedule_section.
    LANDSCAPE_PGMAR_XML = '<w:pgMar w:top="1701" w:right="1418" w:bottom="1701" w:left="1418" w:header="708" w:footer="708" w:gutter="0"/>'

    # Insere o bloco de cronograma no .docx do consultor (não no modelo). Se já houver um bloco
    # (o .docx gerado pelo sistema quase sempre tem — legenda "Quadro 9-N"), remove o antigo e põe
    # o novo no lugar, pra não sair cronograma duplicado num documento que vai pro cliente.
    def insert_or_replace_schedule_block!(doc, schedules, zip, sect_props)
      portrait_sect, landscape_sect = sect_props
      xml = schedule_block_xml(schedules, zip, portrait_sect: portrait_sect, landscape_sect: landscape_sect)
      raise SectionAnchorError, "Não consegui montar o bloco de cronograma." if xml.blank?

      children = doc.at_xpath("//w:body", NS).children.to_a
      fragment = Nokogiri::XML::DocumentFragment.parse(xml)

      if (range = existing_schedule_block_range(children))
        children[range.begin].add_previous_sibling(fragment)
        range.each { |i| children[i].remove }
      else
        schedule_anchor_node(children).add_previous_sibling(fragment)
      end
    end

    # Bloco de cronograma já presente: legenda "Quadro 11-N: …" cercada por dois parágrafos com
    # <w:sectPr> (retrato antes, paisagem depois — ver schedule_block_xml). Num .docx gerado pelo
    # sistema esses são os ÚNICOS <w:sectPr> em nível de parágrafo (a capa usa titlePg, não seção
    # própria), então varrer irmãos pra trás/frente a partir da legenda acha os limites do bloco.
    # Aceita "Quadro 9-"/"Quadro 10-" também: docs gerados antes de 2026-09 (quando PRAZO era a
    # 9ª, depois a 10ª seção) ainda circulam, e reinserir cronograma neles não pode duplicar o
    # bloco. O "· Cronograma" é o que distingue essa legenda da do EQUIPE (também "Quadro 9-1"
    # desde 2026-09).
    SCHEDULE_CAPTION_PREFIXES = [ "Quadro #{SECAO_PRAZO_NUMERO}-", "Quadro 10-", "Quadro 9-" ].uniq.freeze

    def existing_schedule_block_range(children)
      caption = children.index do |node|
        next false unless node.name == "p"

        text = node.xpath(".//w:t", NS).map(&:text).join.strip
        text.include?("Cronograma") && SCHEDULE_CAPTION_PREFIXES.any? { |prefix| text.start_with?(prefix) }
      end
      return nil unless caption

      start_i = caption.downto(0).find { |i| section_break_paragraph?(children[i]) }
      end_i = (caption...children.size).find { |i| section_break_paragraph?(children[i]) }
      return nil unless start_i && end_i && start_i < end_i

      start_i..end_i
    end

    def section_break_paragraph?(node)
      node.name == "p" && !node.at_xpath("./w:pPr/w:sectPr", NS).nil?
    end

    # Onde inserir quando ainda não há bloco: logo ANTES do próximo Título 1 depois de "PRAZO DE
    # EXECUÇÃO" (fim da seção 9). Sem essa seção no documento não dá pra ancorar nada.
    def schedule_anchor_node(children)
      heading = children.index do |node|
        node.name == "p" && node.xpath(".//w:t", NS).map(&:text).join.strip.upcase.start_with?(SCHEDULE_ANCHOR_HEADING)
      end
      raise SectionAnchorError, "Não encontrei a seção \"PRAZO DE EXECUÇÃO\" no documento — sem ela não sei onde encaixar o cronograma." unless heading

      next_heading = ((heading + 1)...children.size).find { |i| heading_style?(children[i]) }
      children[next_heading || (children.size - 1)]
    end

    # Props de seção (cabeçalho/rodapé/tamanho de página) a partir do <w:sectPr> final do corpo do
    # .docx enviado — string, não Nokogiri, pra a saída ser previsível e não arrastar declaração de
    # namespace redundante. Fallback pras constantes do modelo se não achar.
    def sect_props_from_xml(document_xml, rels_xml = "")
      final = document_xml[%r{<w:sectPr\b[^>]*>.*?</w:sectPr>(?=\s*</w:body>)}m]
      return [ PORTRAIT_SECT_XML, LANDSCAPE_SECT_XML ] unless final

      inner = final.sub(%r{\A<w:sectPr\b[^>]*>}, "").sub(%r{</w:sectPr>\z}, "")
      refs = inner.scan(%r{<w:(?:header|footer)Reference\b[^>]*/>}).join
      refs = SECT_HEADER_FOOTER_XML if refs.empty?

      pgsz = inner[%r{<w:pgSz\b[^>]*/>}] || '<w:pgSz w:w="11906" w:h="16838"/>'
      width = pgsz[/w:w="(\d+)"/, 1] || "11906"
      height = pgsz[/w:h="(\d+)"/, 1] || "16838"
      pgmar = inner[%r{<w:pgMar\b[^>]*/>}] ||
        '<w:pgMar w:top="1417" w:right="1701" w:bottom="1417" w:left="1701" w:header="708" w:footer="708" w:gutter="0"/>'

      portrait = "#{refs}#{pgsz}#{pgmar}"
      landscape = %(#{landscape_refs(refs, rels_xml)}<w:pgSz w:orient="landscape" w:w="#{height}" w:h="#{width}"/>#{LANDSCAPE_PGMAR_XML})
      [ portrait, landscape ]
    end

    # Troca o footerReference pelo rodapé paisagem (footer2.xml, offsets recentralizados) quando o
    # .docx já o traz registrado — todo .docx gerado a partir do modelo atual traz. Se não trouxer
    # (gerado por um modelo antigo), mantém o rodapé retrato: sai levemente torto na paisagem, mas
    # nunca dangling ref (que o Word abre com aviso).
    def landscape_refs(portrait_refs, rels_xml)
      footer2_id = rels_xml[%r{<Relationship[^>]*Target="footer2\.xml"[^>]*/>}]&.[](/Id="([^"]+)"/, 1)
      return portrait_refs unless footer2_id

      portrait_refs.sub(%r{(<w:footerReference\b[^>]*\br:id=")[^"]+(")}, "\\1#{footer2_id}\\2")
    end

    # word/media/*.png já é declarado pelo [Content_Types].xml de todo .docx gerado pelo sistema
    # (herda do modelo). Rede de segurança caso um "Salvar como" tenha mexido nisso.
    def ensure_png_content_type!(zip)
      types = zip.read("[Content_Types].xml")
      return if types.include?('Extension="png"')

      patched = types.sub(%r{(<Types\b[^>]*>)}, %(\\1<Default Extension="png" ContentType="image/png"/>))
      zip.get_output_stream("[Content_Types].xml") { |f| f.write(patched) }
    end

    # Infográfico visual (ScheduleTimelineRenderer) ANTES da legenda+tabela do mesmo tipo —
    # resumo primeiro, detalhe auditável depois. Não bloqueia nada: sem rsvg-convert instalado,
    # ou cronograma sem itens, o renderer devolve nil e só a tabela (de sempre) aparece — mesma
    # filosofia não-bloqueante do mapa (Mapbox) e do MSPDI.
    def schedule_timeline_xml(type, payload, zip)
      results = ScheduleTimelineRenderer.new(
        items: payload[:items], start_date: payload[:start_date], unit: SCHEDULE_UNITS.fetch(type),
        key_points: payload[:key_points] || []
      ).call

      # Um Result por IMAGEM (normalmente uma só; mais de uma quando o cronograma tem linhas
      # demais pra caber numa página só — ver ScheduleTimelineRenderer::MAX_IMAGE_HEIGHT_EMU).
      # Cada uma vira seu PRÓPRIO parágrafo — Word/LibreOffice flui cada imagem que sozinha cabe
      # numa página pra próxima página sozinho, sem precisar de quebra de página manual.
      results.each_with_index.map do |result, index|
        filename = "cronograma_#{type}_#{index + 1}.png"
        rel_id = "rId_CRONOGRAMA_#{type.upcase}_#{index + 1}"
        write_image!(zip, rel_id, filename, result.png_bytes)

        centered_paragraph_xml(drawing_run_xml(rel_id, filename, result.width_emu, result.height_emu))
      end.join
    end

    def centered_paragraph_xml(run_xml)
      "<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" \
      "<w:pPr><w:jc w:val=\"center\"/></w:pPr>#{run_xml}</w:p>"
    end

    def schedule_caption_xml(text)
      "<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" \
      "<w:pPr><w:jc w:val=\"both\"/><w:rPr><w:rFonts w:ascii=\"Metropolis\" w:hAnsi=\"Metropolis\"/><w:b/></w:rPr></w:pPr>" \
      "<w:r><w:rPr><w:rFonts w:ascii=\"Metropolis\" w:hAnsi=\"Metropolis\"/><w:b/></w:rPr>" \
      "<w:t xml:space=\"preserve\">#{CGI.escapeHTML(text)}</w:t></w:r></w:p>"
    end

    def section_break_paragraph_xml(sect_xml)
      "<w:p xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:pPr><w:sectPr>#{sect_xml}</w:sectPr></w:pPr></w:p>"
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

    # Quadro SUMÁRIO DE REVISÕES (índice 0) — duas diferenças do resto das tabelas:
    #
    # 1. `header_rows: 2` — as outras tabelas têm 1 linha de cabeçalho (rótulos das colunas) antes
    #    da 1ª linha de dado; esta tem DUAS ("SUMÁRIO DE REVISÕES", título mesclado, e só depois
    #    "Revisão | Descrição da Revisão | Data", os rótulos de verdade). Usar o `header_rows: 1`
    #    genérico aqui pegava a linha de RÓTULOS como se fosse a 1ª linha de dado (o "molde") —
    #    achado ao vivo nesta sessão: o cabeçalho sumia de todo `.docx` gerado, sobrescrito pelos
    #    valores da revisão "00" ("Revisão"→"00", "Descrição da Revisão"→"Emissão Inicial" etc.).
    # 2. `trim: false` — o molde do modelo já vem com as linhas "00" a "10" pré-numeradas (11
    #    linhas, Descrição/Data em branco) — pedido do consultor (2026-09) pra SEMPRE aparecerem,
    #    mesmo numa proposta com poucas revisões, em vez de sumirem (o `fill_table!` de sempre
    #    apaga a linha do molde que sobra sem dado, comportamento certo pras OUTRAS tabelas —
    #    equipe/produtos/desembolso não têm "linha vazia de reserva"). Sem `trim`, sobra
    #    exatamente o molde original quando `rows_data` for menor que ele, e ainda clona linha
    #    nova se um dia passar de 10 revisões (version > 11) — mesma lógica de crescimento de
    #    sempre.
    #
    # `auto_number: false` porque a 1ª coluna já vem pronta em Proposal#docx_revision_rows,
    # formatada "01"/"02"..., porque é `version - 1`, não uma contagem de linha; auto_number
    # reescreveria por cima errado.
    def fill_revisions_table!(tbl, rows_data)
      fill_table!(tbl, rows_data, auto_number: false, trim: false, header_rows: 2)
    end

    # tbl: nó <w:tbl>. A linha logo após `header_rows` (1 por padrão — a linha de rótulos das
    # colunas) vira o "molde": clonada se faltar linha; removida se sobrar, a menos que
    # `trim: false` (ver #fill_revisions_table!, a única chamadora que passa isso ou um
    # `header_rows` diferente). auto_number preenche a 1ª coluna com 1..N e desloca rows_data uma
    # coluna pra direita, então quem chama só passa as colunas de conteúdo de verdade.
    def fill_table!(tbl, rows_data, auto_number:, trim: true, header_rows: 1)
      return unless tbl

      all_rows = tbl.xpath(".//w:tr", NS)
      template_row = all_rows[header_rows]
      existing_data_rows = all_rows[header_rows..]
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

      existing_data_rows[rows_data.size..].to_a.each(&:remove) if trim && rows_data.size < existing_data_rows.size
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
