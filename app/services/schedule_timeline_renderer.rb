# Infográfico horizontal do cronograma (círculo numerado + ícone + linha conectando + título/
# data/duração por etapa) — resumo visual pedido pelo consultor pra somar à tabela auditável que
# já existe (Quadro 9-1, ScheduleTableBuilder), nunca no lugar dela. Ver CLAUDE.md seção 8.
#
# Gera SVG cru (mesmo estilo de AreaSketchRenderer: heredoc + método privado por elemento, sem
# gem de gráficos) e RASTERIZA pra PNG antes de devolver — SVG nunca chega no .docx neste projeto
# (o [Content_Types].xml do modelo só declara PNG/JPG; ver GenerateProposalDocumentTool#
# build_images, mesma decisão já tomada pro croqui do KMZ). Rasterização via `rsvg-convert`
# (pacote `librsvg2-bin`, não é gem Ruby) — mesmo padrão de "shell pra binário externo, sem
# bloquear o resto se faltar" já usado pro helper Java do MSPDI e pro pdftoppm/tesseract do OCR
# do RAG.
#
# `items` tem que vir na ORDEM de exibição (por `position`, ver ScheduleItem.for_type) — cada
# item vira UM círculo (a fase não vira círculo próprio, só as atividades — igual a referência
# trazida pelo consultor). Datas calculadas com a MESMA conta de ScheduleMspdiExporter#item_start/
# #item_finish (duplicada aqui de propósito, mesmo princípio de não abstrair cedo demais — ver
# CLAUDE.md seção 11.1, "Decisão de design").
require "open3"

class ScheduleTimelineRenderer
  class RasterizerError < StandardError; end

  Result = Data.define(:png_bytes, :width_emu, :height_emu)

  # Cronogramas reais no sistema já chegam a ter 30-47 itens — uma linha só de círculos não cabe
  # na largura da página. Quebra em várias linhas (largura da página fica fixa, a imagem cresce
  # em ALTURA conforme o número de linhas) em vez de espremer os círculos até ficar ilegível.
  ITEMS_PER_ROW = 6

  CIRCLE_R = 40
  BADGE_R = 15
  COLUMN_WIDTH = 220
  ROW_TOP_PADDING = 24
  LABEL_START_GAP = 22
  UNDERLINE_BLOCK_HEIGHT = 14
  UNDERLINE_WIDTH = 28
  LABEL_LINE_HEIGHT = 20
  LABEL_MAX_LINES = 3
  DATE_LINE_HEIGHT = 16
  DATE_BLOCK_HEIGHT = DATE_LINE_HEIGHT * 2 # intervalo de datas + duração, sempre 2 linhas
  ROW_BOTTOM_PADDING = 16
  MAX_CHARS_PER_LINE = 22
  LINE_OVERHANG = 26 # quanto a linha/seta passa do centro do último círculo da linha

  # Degradê quente→frio (âmbar → verde-oliva → verde → verde-azulado → azul-petróleo → azul →
  # azul-escuro), pedido pelo consultor pra bater com uma referência real da Papyrus — cada etapa
  # pega uma cor ao longo desse degradê conforme sua posição no cronograma INTEIRO (não por
  # linha/imagem, pra ficar contínuo mesmo quando o cronograma quebra em várias imagens). Termina
  # no mesmo azul-escuro do Quadro 9-1 (ScheduleTableBuilder::HEADER_GROUP_FILL) — só essa ponta
  # mantém a paleta já usada na tabela, o resto é a variação pedida.
  GRADIENT_STOPS = %w[F2A93B 9BB93C 4FAE64 2FA98C 1F9AA0 1F7FB0 1F63A8 1F4E79].freeze
  TEXT_COLOR = "333333"
  DATE_COLOR = "666666"

  # Largura de impressão alvo ~9,5pol (cabe na largura útil da página paisagem — mesma
  # USABLE_WIDTH de ScheduleTableBuilder, 14002dxa ≈ 9,72pol). Altura sai proporcional ao viewBox.
  PRINT_WIDTH_EMU = 8_686_800
  RASTER_DPI = 150

  # Achado ao vivo (proposta 21, cronograma de 34 itens/6 linhas): uma imagem SÓ com todas as
  # linhas ficava mais alta que uma página paisagem inteira, e o Word/LibreOffice simplesmente
  # CORTAVA as linhas de baixo — sem erro, sem aviso, as duas últimas fases do cronograma real
  # sumiam do documento. ~5,25pol (com folga pro cabeçalho/logo da página e alguma margem antes
  # da legenda/tabela que vem depois) é o teto seguro de altura por imagem — cronograma que não
  # cabe numa imagem só vira VÁRIAS imagens (uma por "página" de linhas, ver #call), cada uma seu
  # próprio parágrafo no .docx — Word/LibreOffice flui cada imagem que sozinha cabe numa página
  # pra próxima página sozinho, sem precisar de quebra de página manual nenhuma.
  MAX_IMAGE_HEIGHT_EMU = 4_800_000

  # Ícone por PALAVRA-CHAVE no título da atividade — mapa fechado, não é a IA decidindo. Sem
  # match nenhum, cai no ícone genérico (:generic). Ordem importa: primeiro match vence.
  ICON_KEYWORDS = [
    [ /aprova/i, :check ],
    [ /mobiliza/i, :people ],
    [ /desloc/i, :truck ],
    [ /campo|campanha/i, :pin ],
    [ /consolida|processa|an[aá]lise|dados/i, :chart ],
    [ /elabora|relat[oó]rio|laudo|memorial/i, :document ],
    [ /revis|emiss[aã]o|\bart\b/i, :check ],
    [ /envio|entrega/i, :plane ],
    [ /protocolo|tramita/i, :folder ],
    [ /reuni[aã]o/i, :people ]
  ].freeze

  # unit: :week (cronograma do serviço) ou :month (cronograma de implantação) — mesmo parâmetro
  # de ScheduleTableBuilder/ScheduleMspdiExporter.
  def initialize(items:, start_date:, unit:)
    @items = items
    @start_date = start_date
    @unit = unit
  end

  # Devolve um Result POR IMAGEM (ver MAX_IMAGE_HEIGHT_EMU) — normalmente uma só, várias quando
  # o cronograma tem linhas demais pra caber numa página. [] quando não há item nenhum, ou nil
  # no lugar de um Result específico quando SÓ aquele pedaço falhou ao rasterizar (rsvg-convert
  # ausente é erro determinístico — ou falha em todos, ou em nenhum, mas o formato protege contra
  # falha parcial de qualquer jeito).
  def call
    return [] if @items.blank?

    item_chunks.each_with_index.filter_map { |chunk, index| render_chunk(chunk, index * items_per_image) }
  end

  # Um array de SVG cru, um por imagem — mesmo agrupamento de #call, exposto à parte (não
  # privado) pra testar a estrutura sem depender do rsvg-convert estar instalado, mesma
  # disciplina de AreaSketchRenderer.
  def svgs
    return [] if @items.blank?

    item_chunks.each_with_index.map { |chunk, index| svg_for(chunk, index * items_per_image) }
  end

  private
    def item_chunks
      @items.each_slice(items_per_image).to_a
    end

    # Quantas linhas cabem sem estourar MAX_IMAGE_HEIGHT_EMU, convertido pra quantidade de itens
    # (linha cheia = ITEMS_PER_ROW). Nunca menos que 1 linha, mesmo que o teto fosse baixo demais
    # — imagem "grande demais mas presente" é preferível a nenhuma imagem.
    def items_per_image
      rows = (MAX_IMAGE_HEIGHT_EMU / emu_per_row).floor
      [ rows, 1 ].max * ITEMS_PER_ROW
    end

    def emu_per_row
      PRINT_WIDTH_EMU * (row_height.to_f / viewbox_width)
    end

    def render_chunk(chunk_items, number_offset)
      png_bytes = rasterize(svg_for(chunk_items, number_offset))
      return nil unless png_bytes

      Result.new(png_bytes: png_bytes, width_emu: PRINT_WIDTH_EMU, height_emu: height_emu_for(chunk_items))
    rescue RasterizerError => e
      Rails.logger.error("ScheduleTimelineRenderer falhou: #{e.message}")
      nil
    end

    def svg_for(chunk_items, number_offset)
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{viewbox_width} #{viewbox_height_for(chunk_items)}">
          <rect width="100%" height="100%" fill="#ffffff"/>
          #{rows_xml(chunk_items, number_offset)}
        </svg>
      SVG
    end

    def viewbox_width
      ITEMS_PER_ROW * COLUMN_WIDTH
    end

    def row_height
      ROW_TOP_PADDING + (CIRCLE_R * 2) + LABEL_START_GAP + (LABEL_MAX_LINES * LABEL_LINE_HEIGHT) +
        UNDERLINE_BLOCK_HEIGHT + DATE_BLOCK_HEIGHT + ROW_BOTTOM_PADDING
    end

    def row_count_for(chunk_items)
      (chunk_items.size / ITEMS_PER_ROW.to_f).ceil
    end

    def viewbox_height_for(chunk_items)
      row_count_for(chunk_items) * row_height
    end

    def height_emu_for(chunk_items)
      (PRINT_WIDTH_EMU * (viewbox_height_for(chunk_items).to_f / viewbox_width)).round
    end

    def rows_xml(chunk_items, number_offset)
      chunk_items.each_slice(ITEMS_PER_ROW).each_with_index.map { |row, index| row_xml(row, index, number_offset) }.join
    end

    def row_xml(row_items, row_index, number_offset)
      row_top = row_index * row_height
      cy = row_top + ROW_TOP_PADDING + CIRCLE_R
      centers = row_items.each_index.map { |i| column_center_x(i) }
      global_index = ->(i) { number_offset + (row_index * ITEMS_PER_ROW) + i }
      colors = row_items.each_index.map { |i| color_for(global_index.call(i)) }

      line = row_items.size > 1 ? connector_xml(row_index, centers, cy, colors) : ""
      circles = row_items.each_with_index.map do |item, i|
        step_xml(item, global_index.call(i) + 1, centers[i], cy, row_top, colors[i])
      end.join

      "#{line}#{circles}"
    end

    # Linha em degradê (um <linearGradient> com um stop na cor de CADA círculo, não só início/fim
    # — o degradê muda suave mesmo com vários tons diferentes numa linha só) + seta no final,
    # igual a referência trazida pelo consultor (a linha "continua" além do último círculo).
    def connector_xml(row_index, centers, cy, colors)
      x1 = centers.first
      x2 = centers.last + LINE_OVERHANG
      gradient_id = "linha-#{row_index}"
      stops = centers.each_with_index.map do |x, i|
        offset = (x - x1).to_f / (x2 - x1)
        %(<stop offset="#{offset.round(4)}" stop-color="##{colors[i]}"/>)
      end.join

      <<~SVG
        <defs><linearGradient id="#{gradient_id}" gradientUnits="userSpaceOnUse" x1="#{x1}" y1="#{cy}" x2="#{x2}" y2="#{cy}">#{stops}</linearGradient></defs>
        <line x1="#{x1}" y1="#{cy}" x2="#{x2 - 10}" y2="#{cy}" stroke="url(##{gradient_id})" stroke-width="4"/>
        <polygon points="#{x2 - 12},#{cy - 7} #{x2},#{cy} #{x2 - 12},#{cy + 7}" fill="##{colors.last}"/>
      SVG
    end

    # Posição (0-based) no cronograma INTEIRO, não na linha/imagem — o degradê fica contínuo
    # mesmo quando o cronograma quebra em várias imagens (a 2ª imagem continua de onde a 1ª
    # parou, nunca reinicia a cor do zero).
    def color_for(global_index)
      total = @items.size
      return GRADIENT_STOPS.first if total <= 1

      position = (global_index.to_f / (total - 1)) * (GRADIENT_STOPS.size - 1)
      lower = position.floor.clamp(0, GRADIENT_STOPS.size - 2)
      blend_hex(GRADIENT_STOPS[lower], GRADIENT_STOPS[lower + 1], position - lower)
    end

    def blend_hex(hex_a, hex_b, t)
      rgb_a = hex_a.scan(/../).map { |part| part.to_i(16) }
      rgb_b = hex_b.scan(/../).map { |part| part.to_i(16) }
      rgb_a.zip(rgb_b).map { |a, b| format("%02X", (a + ((b - a) * t)).round.clamp(0, 255)) }.join
    end

    def column_center_x(index_in_row)
      (index_in_row * COLUMN_WIDTH) + (COLUMN_WIDTH / 2)
    end

    # Círculo em ANEL (contorno colorido, miolo branco) com o ícone na MESMA cor do anel — não
    # preenchido sólido com ícone branco (versão anterior) — pra bater com a referência trazida
    # pelo consultor.
    def step_xml(item, number, cx, cy, row_top, color)
      <<~SVG
        <circle cx="#{cx}" cy="#{cy}" r="#{CIRCLE_R}" fill="#ffffff" stroke="##{color}" stroke-width="4"/>
        #{icon_xml(icon_for(item), cx, cy, color)}
        #{badge_xml(number, cx - (CIRCLE_R * 0.7), cy - (CIRCLE_R * 0.7), color)}
        #{labels_xml(item, cx, row_top, cy, color)}
      SVG
    end

    def badge_xml(number, cx, cy, color)
      <<~SVG
        <circle cx="#{cx}" cy="#{cy}" r="#{BADGE_R}" fill="##{color}" stroke="#ffffff" stroke-width="2"/>
        #{text_tag(cx, cy + 5, format("%02d", number), size: 14, color: "ffffff", weight: "bold")}
      SVG
    end

    # Sublinhado e data sempre na MESMA posição vertical dentro da linha — reserva o espaço de
    # LABEL_MAX_LINES sempre, não só o que o título de fato ocupa, pra títulos de tamanhos
    # diferentes não desalinharem o resto da etiqueta entre um círculo e outro da mesma linha
    # (mesmo orçamento vertical que row_height já reserva por linha).
    def labels_xml(item, cx, row_top, cy, color)
      top = cy + CIRCLE_R + LABEL_START_GAP

      title_lines = wrap_text(item.activity_name, MAX_CHARS_PER_LINE)
      title_xml = title_lines.each_with_index.map do |line, i|
        text_tag(cx, top + (i * LABEL_LINE_HEIGHT), line, size: 13, color: TEXT_COLOR, weight: "bold")
      end.join

      underline_y = top + (LABEL_MAX_LINES * LABEL_LINE_HEIGHT) - (LABEL_LINE_HEIGHT / 2) + (UNDERLINE_BLOCK_HEIGHT / 2)
      underline = %(<line x1="#{cx - (UNDERLINE_WIDTH / 2)}" y1="#{underline_y}" x2="#{cx + (UNDERLINE_WIDTH / 2)}" y2="#{underline_y}" stroke="##{color}" stroke-width="3"/>)

      date_top = top + (LABEL_MAX_LINES * LABEL_LINE_HEIGHT) + UNDERLINE_BLOCK_HEIGHT
      date_xml = date_lines(item).each_with_index.map do |line, i|
        text_tag(cx, date_top + (i * DATE_LINE_HEIGHT), line, size: 11, color: DATE_COLOR)
      end.join

      "#{title_xml}#{underline}#{date_xml}"
    end

    def text_tag(x, y, text, size:, color:, weight: nil)
      weight_attr = weight ? %( font-weight="#{weight}") : ""
      %(<text x="#{x}" y="#{y}" text-anchor="middle" font-family="Arial, sans-serif" font-size="#{size}"#{weight_attr} fill="##{color}">#{escape(text)}</text>)
    end

    # Quebra em até LABEL_MAX_LINES linhas por largura de caractere; se ainda sobrar palavra,
    # trunca a última linha com reticência em vez de estourar a coluna.
    def wrap_text(text, max_chars)
      lines = []
      current = +""

      text.to_s.split.each do |word|
        candidate = current.empty? ? word : "#{current} #{word}"
        if candidate.length > max_chars && current.present?
          lines << current
          current = word
        else
          current = candidate
        end
      end
      lines << current if current.present?

      return lines if lines.size <= LABEL_MAX_LINES

      truncated = lines.first(LABEL_MAX_LINES)
      truncated[-1] = "#{truncated.last.rstrip}…"
      truncated
    end

    # Marco (ponto no tempo, sem duração) mostra "-" no lugar de uma duração calculada — igual a
    # referência trazida pelo consultor, onde as etapas pontuais não trazem número de dias
    # nenhum. Etapa normal mostra o intervalo de datas e a duração em dias corridos.
    def date_lines(item)
      start_date = item_start(item)
      return [ formatted(start_date), "-" ] if item.milestone?

      finish_date = item_finish(item)
      duration_days = (finish_date - start_date).to_i

      range = start_date == finish_date ? formatted(start_date) : "#{formatted(start_date)} a #{formatted(finish_date)}"
      # String#pluralize é baseado nas regras de inflexão do INGLÊS (config.i18n.default_locale
      # sendo pt-BR não muda isso — é ActiveSupport::Inflector, não I18n) e não pluraliza "dia"
      # corretamente ("dia".pluralize(7) => "dia", errado) — regra do português é só o "s" mesmo,
      # sem tentar usar o inflector genérico pra uma palavra que ele não conhece.
      duration = "#{duration_days} #{duration_days == 1 ? 'dia' : 'dias'}"

      [ range, duration ]
    end

    def formatted(date)
      date.strftime("%d/%m/%Y")
    end

    # Mesma conta de ScheduleMspdiExporter#item_start/#item_finish — duplicada de propósito
    # (ver comentário no topo do arquivo).
    def item_start(item)
      case @unit
      when :week then @start_date + ((item.start_period - 1) * 7)
      when :month then @start_date >> (item.start_period - 1)
      end
    end

    def item_finish(item)
      case @unit
      when :week then @start_date + ((item.start_period - 1 + item.duration_periods) * 7)
      when :month then @start_date >> (item.start_period - 1 + item.duration_periods)
      end
    end

    def icon_for(item)
      _pattern, symbol = ICON_KEYWORDS.find { |pattern, _symbol| item.activity_name.match?(pattern) }
      symbol || :generic
    end

    # Heroicons v2 "solid" (24×24, MIT — github.com/tailwindlabs/heroicons), path cru copiado tal
    # e qual do pacote oficial — mesma linguagem visual que o resto do sistema já usa nas views
    # (SVG inline estilo Heroicons). Achado ao vivo: o primeiro rascunho desenhava ícone na mão
    # com formas geométricas simples (círculo, retângulo, triângulo) e ficava tosco perto do
    # exemplo real trazido pelo consultor — ícone de verdade, não geometria improvisada.
    ICON_SCALE = 1.6
    ICON_VIEWBOX_CENTER = 12

    CHECK_PATHS = '<path fill-rule="evenodd" d="M19.916 4.626a.75.75 0 0 1 .208 1.04l-9 13.5a.75.75 0 0 1-1.154.114l-6-6a.75.75 0 0 1 1.06-1.06l5.353 5.353 8.493-12.74a.75.75 0 0 1 1.04-.207Z" clip-rule="evenodd"/>'.freeze
    PEOPLE_PATHS = '<path d="M4.5 6.375a4.125 4.125 0 1 1 8.25 0 4.125 4.125 0 0 1-8.25 0ZM14.25 8.625a3.375 3.375 0 1 1 6.75 0 3.375 3.375 0 0 1-6.75 0ZM1.5 19.125a7.125 7.125 0 0 1 14.25 0v.003l-.001.119a.75.75 0 0 1-.363.63 13.067 13.067 0 0 1-6.761 1.873c-2.472 0-4.786-.684-6.76-1.873a.75.75 0 0 1-.364-.63l-.001-.122ZM17.25 19.128l-.001.144a2.25 2.25 0 0 1-.233.96 10.088 10.088 0 0 0 5.06-1.01.75.75 0 0 0 .42-.643 4.875 4.875 0 0 0-6.957-4.611 8.586 8.586 0 0 1 1.71 5.157v.003Z"/>'.freeze
    TRUCK_PATHS = ('<path d="M3.375 4.5C2.339 4.5 1.5 5.34 1.5 6.375V13.5h12V6.375c0-1.036-.84-1.875-1.875-1.875h-8.25ZM13.5 15h-12v2.625c0 1.035.84 1.875 1.875 1.875h.375a3 3 0 1 1 6 0h3a.75.75 0 0 0 .75-.75V15Z"/>' \
      '<path d="M8.25 19.5a1.5 1.5 0 1 0-3 0 1.5 1.5 0 0 0 3 0ZM15.75 6.75a.75.75 0 0 0-.75.75v11.25c0 .087.015.17.042.248a3 3 0 0 1 5.958.464c.853-.175 1.522-.935 1.464-1.883a18.659 18.659 0 0 0-3.732-10.104 1.837 1.837 0 0 0-1.47-.725H15.75Z"/>' \
      '<path d="M19.5 19.5a1.5 1.5 0 1 0-3 0 1.5 1.5 0 0 0 3 0Z"/>').freeze
    PIN_PATHS = '<path fill-rule="evenodd" d="m11.54 22.351.07.04.028.016a.76.76 0 0 0 .723 0l.028-.015.071-.041a16.975 16.975 0 0 0 1.144-.742 19.58 19.58 0 0 0 2.683-2.282c1.944-1.99 3.963-4.98 3.963-8.827a8.25 8.25 0 0 0-16.5 0c0 3.846 2.02 6.837 3.963 8.827a19.58 19.58 0 0 0 2.682 2.282 16.975 16.975 0 0 0 1.145.742ZM12 13.5a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z" clip-rule="evenodd"/>'.freeze
    CHART_PATHS = '<path d="M18.375 2.25c-1.035 0-1.875.84-1.875 1.875v15.75c0 1.035.84 1.875 1.875 1.875h.75c1.035 0 1.875-.84 1.875-1.875V4.125c0-1.036-.84-1.875-1.875-1.875h-.75ZM9.75 8.625c0-1.036.84-1.875 1.875-1.875h.75c1.036 0 1.875.84 1.875 1.875v11.25c0 1.035-.84 1.875-1.875 1.875h-.75a1.875 1.875 0 0 1-1.875-1.875V8.625ZM3 13.125c0-1.036.84-1.875 1.875-1.875h.75c1.036 0 1.875.84 1.875 1.875v6.75c0 1.035-.84 1.875-1.875 1.875h-.75A1.875 1.875 0 0 1 3 19.875v-6.75Z"/>'.freeze
    DOCUMENT_PATHS = ('<path fill-rule="evenodd" d="M5.625 1.5c-1.036 0-1.875.84-1.875 1.875v17.25c0 1.035.84 1.875 1.875 1.875h12.75c1.035 0 1.875-.84 1.875-1.875V12.75A3.75 3.75 0 0 0 16.5 9h-1.875a1.875 1.875 0 0 1-1.875-1.875V5.25A3.75 3.75 0 0 0 9 1.5H5.625ZM7.5 15a.75.75 0 0 1 .75-.75h7.5a.75.75 0 0 1 0 1.5h-7.5A.75.75 0 0 1 7.5 15Zm.75 2.25a.75.75 0 0 0 0 1.5H12a.75.75 0 0 0 0-1.5H8.25Z" clip-rule="evenodd"/>' \
      '<path d="M12.971 1.816A5.23 5.23 0 0 1 14.25 5.25v1.875c0 .207.168.375.375.375H16.5a5.23 5.23 0 0 1 3.434 1.279 9.768 9.768 0 0 0-6.963-6.963Z"/>').freeze
    PLANE_PATHS = '<path d="M3.478 2.404a.75.75 0 0 0-.926.941l2.432 7.905H13.5a.75.75 0 0 1 0 1.5H4.984l-2.432 7.905a.75.75 0 0 0 .926.94 60.519 60.519 0 0 0 18.445-8.986.75.75 0 0 0 0-1.218A60.517 60.517 0 0 0 3.478 2.404Z"/>'.freeze
    FOLDER_PATHS = '<path d="M19.5 21a3 3 0 0 0 3-3v-4.5a3 3 0 0 0-3-3h-15a3 3 0 0 0-3 3V18a3 3 0 0 0 3 3h15ZM1.5 10.146V6a3 3 0 0 1 3-3h5.379a2.25 2.25 0 0 1 1.59.659l2.122 2.121c.14.141.331.22.53.22H19.5a3 3 0 0 1 3 3v1.146A4.483 4.483 0 0 0 19.5 9h-15a4.483 4.483 0 0 0-3 1.146Z"/>'.freeze
    GENERIC_PATHS = '<circle cx="12" cy="12" r="5"/>'.freeze

    # Ícone na MESMA cor do anel do círculo (miolo branco, anel + ícone coloridos) — não branco
    # fixo, pra bater com a referência trazida pelo consultor.
    def icon_xml(symbol, cx, cy, color)
      %(<g transform="translate(#{cx},#{cy}) scale(#{ICON_SCALE}) translate(-#{ICON_VIEWBOX_CENTER},-#{ICON_VIEWBOX_CENTER})" fill="##{color}">#{icon_paths(symbol)}</g>)
    end

    def icon_paths(symbol)
      case symbol
      when :check then CHECK_PATHS
      when :people then PEOPLE_PATHS
      when :truck then TRUCK_PATHS
      when :pin then PIN_PATHS
      when :chart then CHART_PATHS
      when :document then DOCUMENT_PATHS
      when :plane then PLANE_PATHS
      when :folder then FOLDER_PATHS
      else GENERIC_PATHS
      end
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end

    def rasterize(svg_source)
      Tempfile.create([ "timeline", ".svg" ]) do |input|
        input.write(svg_source)
        input.flush

        Tempfile.create([ "timeline", ".png" ], binmode: true) do |output|
          run_rsvg!(input.path, output.path)
          File.binread(output.path)
        end
      end
    end

    def run_rsvg!(input_path, output_path)
      _stdout, stderr, status = Open3.capture3("rsvg-convert", "-o", output_path, input_path)
      raise RasterizerError, stderr.presence || "rsvg-convert falhou" unless status.success?
    rescue Errno::ENOENT
      raise RasterizerError, "rsvg-convert não está instalado (pacote librsvg2-bin)"
    end
end
