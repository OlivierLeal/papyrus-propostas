# Monta o XML de uma tabela de cronograma (Gantt) pronta pra entrar no .docx — ver CLAUDE.md
# seção 8 e ScheduleItem. Baseado num exemplo real da Papyrus (PTC26098_Newave Energia, Quadro
# 9-1): colunas de período (semana/mês) agrupadas num cabeçalho de 2 linhas, linha de FASE (fundo
# colorido em toda a linha, sem barra) e linha de ATIVIDADE (ID + nome + barra colorida nos
# períodos em que roda).
#
# `items` tem que já vir na ORDEM de exibição (por `position`, ver ScheduleItem.for_type) — o
# agrupamento por fase é feito detectando troca de `phase_name` entre itens CONSECUTIVOS, não por
# um campo próprio.
#
# Devolve só o `<w:tbl>...</w:tbl>` — legenda/número do quadro e a quebra de seção paisagem ficam
# por conta de quem chama (ProposalDocxFiller), que é quem sabe o número do quadro e onde inserir.
class ScheduleTableBuilder
  # Namespace declarado no próprio <w:tbl> — o fragmento é parseado fora do contexto do documento
  # principal (mesmo motivo de ProposalDocxFiller#drawing_run_xml), então não herda as declarações
  # da raiz <w:document>.
  NS_DECL = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'.freeze

  # Larguras em dxa (1/20 pt), confirmadas no exemplo real. USABLE_WIDTH = largura útil da página
  # paisagem (16838 - 1418×2 de margem).
  ID_COL_WIDTH = 407
  NAME_COL_WIDTH = 1632
  USABLE_WIDTH = 14002

  HEADER_GROUP_FILL = "1F4E79"
  HEADER_PERIOD_FILL = "2F5597"
  PHASE_FILL = "D9E1F2"
  PHASE_TEXT_COLOR = "1F4E79"
  BAR_FILL = "2E75B6"
  MILESTONE_FILL = "C65911"
  BORDER_COLOR = "D9D9D9"
  WHITE = "FFFFFF"

  MONTH_NAMES_PT = %w[Janeiro Fevereiro Março Abril Maio Junho Julho Agosto Setembro Outubro Novembro Dezembro].freeze

  # Abaixo disso, "Sem 12"/"Setembro 2026" não cabe na horizontal — em vez de deixar o Word
  # quebrar letra por letra, gira o texto do cabeçalho 90°. Um cronograma "normal" (poucos meses,
  # como o exemplo real de referência) nunca cruza esse limiar e continua saindo horizontal.
  ROTATE_BELOW_WIDTH = 500

  # Abaixo disso o texto GIRADO some por completo — achado ao vivo testando célula por célula
  # (150/200dxa: em branco; 300dxa: bordas cortadas; 400dxa: perfeito) — o LibreOffice/Word
  # precisam de largura mínima mesmo pra texto vertical, porque a "altura de linha" da fonte vira
  # a dimensão horizontal depois do giro. Quando um período (semana/mês) sozinho não cabe nem
  # girado, CONSOLIDA vários períodos numa coluna só (ver #bucket_size) em vez de deixar a coluna
  # murchar até ficar ilegível — foi assim que um cronograma real de 104 semanas (2 anos de
  # monitoramento, sugerido pela própria IA) saía com o cabeçalho inteiro em branco.
  MIN_COLUMN_WIDTH = 400

  # unit: :week (cronograma do serviço) ou :month (cronograma de implantação do empreendimento).
  def initialize(items, start_date:, unit:)
    @items = items
    @start_date = start_date
    @unit = unit
  end

  def build_xml
    return "" if @items.empty?

    groups, period_labels = period_grouping

    "<w:tbl #{NS_DECL}>#{table_pr_xml}<w:tblGrid>#{grid_cols_xml}</w:tblGrid>" \
    "#{header_group_row_xml(groups)}#{header_period_row_xml(period_labels)}#{data_rows_xml}</w:tbl>"
  end

  private
    # Quantidade real de semanas/meses cobertos pelos itens — usada pra mapear o intervalo
    # [start_period, start_period+duration) de cada atividade pro "bucket" (coluna consolidada)
    # certo. Nunca vira coluna diretamente quando bucket_size > 1 (ver #display_periods).
    def total_periods
      @total_periods ||= @items.map { |item| item.start_period + item.duration_periods - 1 }.max
    end

    # Máximo de colunas que cabem na largura útil sem nenhuma ficar abaixo de MIN_COLUMN_WIDTH.
    def max_display_periods
      @max_display_periods ||= (USABLE_WIDTH - ID_COL_WIDTH - NAME_COL_WIDTH) / MIN_COLUMN_WIDTH
    end

    # 1 = cada período vira sua própria coluna (caso comum). > 1 = cada coluna passa a
    # representar `bucket_size` períodos consecutivos ("Sem 1-4"), só quando período por período
    # não coube de jeito nenhum.
    def bucket_size
      @bucket_size ||= (total_periods.to_f / max_display_periods).ceil.clamp(1, total_periods)
    end

    def display_periods
      @display_periods ||= (total_periods.to_f / bucket_size).ceil
    end

    # Bucket (1-based) a que um período bruto (1-based) pertence.
    def bucket_for(raw_period)
      ((raw_period - 1) / bucket_size) + 1
    end

    # Primeiro período bruto coberto por um bucket — é dele que sai a data usada pro agrupamento
    # por mês/ano e pro rótulo "Sem N"/"Sem A-B".
    def bucket_start_period(bucket)
      ((bucket - 1) * bucket_size) + 1
    end

    def period_width
      @period_width ||= (USABLE_WIDTH - ID_COL_WIDTH - NAME_COL_WIDTH) / display_periods
    end

    def rotate_headers?
      period_width < ROTATE_BELOW_WIDTH
    end

    def table_pr_xml
      total_width = ID_COL_WIDTH + NAME_COL_WIDTH + (period_width * display_periods)
      "<w:tblPr><w:tblW w:w=\"#{total_width}\" w:type=\"dxa\"/><w:jc w:val=\"center\"/>" \
      "<w:tblLayout w:type=\"fixed\"/></w:tblPr>"
    end

    def grid_cols_xml
      cols = +"<w:gridCol w:w=\"#{ID_COL_WIDTH}\"/><w:gridCol w:w=\"#{NAME_COL_WIDTH}\"/>"
      display_periods.times { cols << "<w:gridCol w:w=\"#{period_width}\"/>" }
      cols
    end

    # Semanas (ou blocos de semanas, ver bucket_size) agrupadas por MÊS civil a partir de
    # start_date; meses agrupados por ANO civil — mesma hierarquia do exemplo real (mês >
    # semana), um nível acima pra cronograma de implantação (ano > mês), já que este pode durar
    # anos.
    def period_grouping
      @unit == :week ? week_grouping : month_grouping
    end

    def week_grouping
      groups = []
      labels = (1..display_periods).map do |bucket|
        raw_start = bucket_start_period(bucket)
        week_start = @start_date + ((raw_start - 1) * 7)
        key = [ week_start.year, week_start.month ]
        if groups.last && groups.last[:key] == key
          groups.last[:span] += 1
        else
          groups << { key: key, span: 1, label: "#{MONTH_NAMES_PT[week_start.month - 1]} #{week_start.year}" }
        end
        period_label(bucket, "Sem")
      end
      [ groups, labels ]
    end

    def month_grouping
      groups = []
      labels = (1..display_periods).map do |bucket|
        raw_start = bucket_start_period(bucket)
        date = @start_date >> (raw_start - 1)
        key = date.year
        if groups.last && groups.last[:key] == key
          groups.last[:span] += 1
        else
          groups << { key: key, span: 1, label: date.year.to_s }
        end
        period_label(bucket, "Mês")
      end
      [ groups, labels ]
    end

    # bucket_size 1: "Sem 7". Consolidado: "Sem 25-28" (intervalo de períodos brutos cobertos).
    def period_label(bucket, prefix)
      return "#{prefix} #{bucket}" if bucket_size == 1

      raw_start = bucket_start_period(bucket)
      raw_end = [ raw_start + bucket_size - 1, total_periods ].min
      "#{prefix} #{raw_start}-#{raw_end}"
    end

    def header_group_row_xml(groups)
      # Só gira o rótulo do grupo se a coluna de UM ÚNICO bucket (o pior caso — um grupo de
      # span 1) já não coubesse — grupos com mais de um bucket por baixo ficam bem mais largos
      # (period_width × span) e continuam horizontais mesmo com o rótulo mais longo do que o da
      # linha de período.
      rotate = rotate_headers?
      cells = [
        cell_xml(width: ID_COL_WIDTH, text: "ID", fill: HEADER_GROUP_FILL, bold: true, color: WHITE, size: 18, align: "center"),
        cell_xml(width: NAME_COL_WIDTH, text: "Fase / Atividade", fill: HEADER_GROUP_FILL, bold: true, color: WHITE, size: 18)
      ]
      groups.each do |group|
        group_width = period_width * group[:span]
        cells << cell_xml(width: group_width, text: group[:label], fill: HEADER_GROUP_FILL, bold: true, color: WHITE,
          size: 18, grid_span: group[:span], align: "center", rotate: rotate && group_width < ROTATE_BELOW_WIDTH)
      end
      row_xml(cells, header: true, height: rotate ? 2000 : 350)
    end

    def header_period_row_xml(period_labels)
      rotate = rotate_headers?
      cells = [ cell_xml(width: ID_COL_WIDTH, fill: HEADER_PERIOD_FILL), cell_xml(width: NAME_COL_WIDTH, fill: HEADER_PERIOD_FILL) ]
      period_labels.each do |label|
        cells << cell_xml(width: period_width, text: label, fill: HEADER_PERIOD_FILL, bold: true, color: WHITE,
          size: 14, align: "center", rotate: rotate)
      end
      row_xml(cells, header: true, height: rotate ? 1000 : 350)
    end

    # Ao trocar phase_name em relação ao item anterior, emite antes a linha de FASE — mesma
    # convenção de agrupamento "Fase:" dos produtos (GenerateProposalDocumentTool#build_tables).
    # A paridade da linha (zebra) conta só as linhas de ATIVIDADE, nunca as de fase.
    def data_rows_xml
      rows = +""
      phase_number = 0
      activity_number = 0
      current_phase = nil
      activity_index = 0

      @items.each do |item|
        if item.phase_name != current_phase
          phase_number += 1
          activity_number = 0
          current_phase = item.phase_name
          rows << phase_row_xml(phase_number, item.phase_name)
        end

        activity_number += 1
        rows << activity_row_xml(phase_number, activity_number, item, zebra: activity_index.odd?)
        activity_index += 1
      end

      rows
    end

    def phase_row_xml(phase_number, phase_name)
      cells = [
        cell_xml(width: ID_COL_WIDTH, text: "#{phase_number}.0", fill: PHASE_FILL, bold: true, color: PHASE_TEXT_COLOR, size: 18),
        cell_xml(width: NAME_COL_WIDTH, text: phase_name, fill: PHASE_FILL, bold: true, color: PHASE_TEXT_COLOR, size: 18)
      ]
      display_periods.times { cells << cell_xml(width: period_width, fill: PHASE_FILL) }
      row_xml(cells)
    end

    def activity_row_xml(phase_number, activity_number, item, zebra:)
      base_fill = zebra ? "F2F5F9" : "auto"
      cells = [
        cell_xml(width: ID_COL_WIDTH, text: "#{phase_number}.#{activity_number}", fill: base_fill, size: 18),
        cell_xml(width: NAME_COL_WIDTH, text: item.activity_name, fill: base_fill, size: 18)
      ]

      first_bucket = bucket_for(item.start_period)
      last_bucket = bucket_for(item.start_period + item.duration_periods - 1)

      (1..display_periods).each do |bucket|
        in_bar = bucket >= first_bucket && bucket <= last_bucket
        fill = in_bar ? (item.milestone? ? MILESTONE_FILL : BAR_FILL) : base_fill
        cells << cell_xml(width: period_width, fill: fill)
      end

      row_xml(cells)
    end

    def row_xml(cells, header: false, height: nil)
      height ||= header ? 350 : 280
      tr_pr = +"<w:trPr>"
      tr_pr << "<w:tblHeader w:val=\"true\"/>" if header
      tr_pr << "<w:trHeight w:val=\"#{height}\" w:hRule=\"atLeast\"/></w:trPr>"

      "<w:tr>#{tr_pr}#{cells.join}</w:tr>"
    end

    # fill nil/"auto" não emite <w:shd> nenhum — mesmo efeito visual (fundo branco/padrão) com
    # menos XML. Bordas em toda célula, sempre (mesmo padrão do exemplo real).
    #
    # rotate: gira o texto 90° (baixo pra cima) — ver ROTATE_BELOW_WIDTH. Célula continua com a
    # MESMA largura fixa (period_width); é só o texto que passa a correr na vertical dentro dela,
    # o que precisa de uma w:trHeight bem maior na linha (ver header_*_row_xml) pra caber.
    def cell_xml(width:, text: nil, fill: nil, bold: false, color: nil, size: nil, grid_span: nil, align: nil, rotate: false)
      tc_pr = +"<w:tcPr><w:tcW w:w=\"#{width}\" w:type=\"dxa\"/>"
      tc_pr << "<w:gridSpan w:val=\"#{grid_span}\"/>" if grid_span && grid_span > 1
      tc_pr << border_xml
      tc_pr << "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"#{fill}\"/>" if fill.present? && fill != "auto"
      # w:tcPr segue uma ORDEM fixa no schema OOXML (tcW, gridSpan, ..., tcBorders, shd, ...,
      # textDirection, ..., vAlign) — textDirection fora de ordem (testado antes de tcBorders/shd)
      # fazia o Word/LibreOffice simplesmente IGNORAR o elemento em silêncio, sem erro nenhum:
      # visto ao vivo, o cabeçalho continuava quebrando letra por letra como se rotate: true nunca
      # tivesse sido passado.
      tc_pr << "<w:textDirection w:val=\"btLr\"/>" if rotate
      tc_pr << "<w:vAlign w:val=\"center\"/></w:tcPr>"

      run_pr = +"<w:rPr><w:rFonts w:ascii=\"Metropolis\" w:hAnsi=\"Metropolis\"/>"
      run_pr << "<w:b/>" if bold
      run_pr << "<w:color w:val=\"#{color}\"/>" if color
      run_pr << "<w:sz w:val=\"#{size}\"/><w:szCs w:val=\"#{size}\"/>" if size
      run_pr << "</w:rPr>"

      # w:spacing explícito (nunca herdado) é essencial aqui: o modelo da Papyrus define
      # w:pPrDefault com "after=160" (espaço depois do parágrafo) — invisível numa célula de
      # texto normal, mas depois de girar 90° (rotate:) essa folga vira LARGURA extra que a
      # célula não tem, e o LibreOffice simplesmente NÃO DESENHA o texto (sem erro, sem clip
      # parcial visível — o cabeçalho inteiro saía em branco). Achado ao vivo comparando um teste
      # isolado (sem estilo nenhum herdado, funcionava a 400dxa) com o documento real (mesma
      # largura, em branco) — só a diferença dos w:pPrDefault do modelo explicava.
      p_pr = +"<w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
      p_pr << "<w:jc w:val=\"#{align}\"/>" if align
      p_pr << "</w:pPr>"

      "<w:tc>#{tc_pr}<w:p>#{p_pr}<w:r>#{run_pr}<w:t xml:space=\"preserve\">#{escape(text.presence || " ")}</w:t></w:r></w:p></w:tc>"
    end

    def border_xml
      %w[top left bottom right].map { |side| "<w:#{side} w:val=\"single\" w:sz=\"4\" w:color=\"#{BORDER_COLOR}\"/>" }
        .then { |sides| "<w:tcBorders>#{sides.join}</w:tcBorders>" }
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end
end
