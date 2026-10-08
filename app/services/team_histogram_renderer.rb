# Histograma de mobilização da equipe (2026-10, pedido da Papyrus: só quando o cliente pede no
# ET/TR): quantos profissionais estão alocados em cada mês do cronograma do serviço, empilhado por
# setor (Diretoria, Gestão, Execução). Estilo da página "Gráficos" do Manual de Identidade Visual
# (grade em Azul Papyrus, barras sólidas da paleta).
#
# Quem está em qual mês: a alocação que a IA passou (`histograma_equipe`, "Nome | 1-3, 5") quando
# houver; sem ela, regra do sistema — Diretoria e Gestão no projeto inteiro, quem tem diária nos
# meses das atividades de campo, quem tem só HH nos meses de elaboração (sem protocolo/análise do
# órgão). Os meses saem do cronograma do serviço, com a mesma conversão semana → mês civil do
# ScheduleTableBuilder.
class TeamHistogramRenderer
  Result = Data.define(:png_bytes, :width_emu, :height_emu)

  WIDTH = 1000
  HEIGHT = 450
  PLOT_LEFT = 70
  PLOT_RIGHT = 975
  PLOT_TOP = 30
  PLOT_BOTTOM = 360
  MONTHS = %w[jan fev mar abr mai jun jul ago set out nov dez].freeze
  SECTORS = { diretoria: "Diretoria", gestao: "Gestão", execucao: "Execução" }.freeze
  COLORS = { diretoria: SvgRasterizer::AZUL_PAPYRUS, gestao: SvgRasterizer::AZUL_MEDIO2, execucao: SvgRasterizer::VERDE_BRASIL_ESCURO }.freeze

  FIELD_ACTIVITY = /campo|campanha|levantamento|vistoria|amostragem|coleta|monitoramento|invent[aá]rio|embarca/i
  NOT_ELABORATION = /protocol|aprova[cç][aã]o|emiss[aã]o d[ae] licen[cç]a|an[aá]lise (?:do|pelo) [oó]rg[aã]o|acompanhamento d[oa] (?:processo|an[aá]lise)/i

  attr_reader :labels, :series

  # members: Proposal::TeamMember; items: ScheduleItem do serviço (semanas); allocations: linhas
  # "Nome | 1-3, 5".
  def self.from_schedule(members:, items:, start_date:, allocations: [])
    return nil if members.empty? || items.empty? || start_date.blank?

    spans = items.map { |item| [ item, month_span(item, start_date) ] }
    total = spans.map { |_, span| span.last }.max
    all_months = (1..total).to_a
    field = spans.select { |item, _| "#{item.phase_name} #{item.activity_name}".match?(FIELD_ACTIVITY) }.flat_map { |_, span| span.to_a }.uniq
    elaboration = spans.reject { |item, _| "#{item.phase_name} #{item.activity_name}".match?(Regexp.union(FIELD_ACTIVITY, NOT_ELABORATION)) }.flat_map { |_, span| span.to_a }.uniq
    given = parse_allocations(allocations, total)

    series = SECTORS.keys.index_with { Array.new(total, 0) }
    members.each do |member|
      months = given[Proposal.normalize_person_name(member.name)] || default_months(member, all_months, field, elaboration)
      months.each { |month| series[member.sector][month - 1] += 1 }
    end

    labels = all_months.map do |month|
      date = start_date.to_date.beginning_of_month >> (month - 1)
      "#{MONTHS[date.month - 1]}/#{date.strftime('%y')}"
    end
    new(labels: labels, series: series)
  end

  def self.month_span(item, start_date)
    first = start_date.to_date + ((item.start_period - 1) * 7)
    last = start_date.to_date + ((item.start_period + item.duration_periods - 2) * 7)
    base = (start_date.year * 12) + start_date.month
    ((first.year * 12) + first.month - base + 1)..((last.year * 12) + last.month - base + 1)
  end

  def self.default_months(member, all_months, field, elaboration)
    return all_months unless member.sector == :execucao

    months = []
    months |= (field.presence || all_months) if member.field_days.positive?
    months |= (elaboration.presence || all_months) if member.man_hours.positive?
    months.sort
  end

  # "Ana Souza | 1-3, 5" → { "ana souza" => [1, 2, 3, 5] }. Mês fora do cronograma é ignorado.
  def self.parse_allocations(lines, total)
    Array(lines).each_with_object({}) do |line, result|
      name, months = line.to_s.split("|", 2).map(&:strip)
      next if name.blank? || months.blank?

      list = months.scan(/(\d+)\s*(?:[-–a]\s*(\d+))?/).flat_map { |from, to| (from.to_i..(to || from).to_i).to_a }
      list = list.select { |month| month.between?(1, total) }.uniq.sort
      result[Proposal.normalize_person_name(name)] = list if list.any?
    end
  end

  def initialize(labels:, series:)
    @labels = labels
    @series = series
  end

  def call
    return nil if totals.all?(&:zero?)

    Result.new(png_bytes: SvgRasterizer.png(svg), width_emu: SvgRasterizer::PORTRAIT_WIDTH_EMU,
      height_emu: (SvgRasterizer::PORTRAIT_WIDTH_EMU * HEIGHT / WIDTH.to_f).round)
  end

  def totals
    @totals ||= @labels.each_index.map { |i| @series.values.sum { |values| values[i] } }
  end

  def svg
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">
        <rect width="#{WIDTH}" height="#{HEIGHT}" fill="#FFFFFF"/>
        #{grid_svg}
        #{bars_svg}
        #{x_labels_svg}
        #{legend_svg}
      </svg>
    SVG
  end

  private
    def step
      @step ||= [ 1, 2, 5, 10, 20 ].find { |candidate| (totals.max / candidate.to_f).ceil <= 8 } || 50
    end

    def y_max
      # Sempre uma faixa acima da barra mais alta, pro número dela não encostar na moldura.
      @y_max ||= ((totals.max / step) + 1) * step
    end

    def y_for(value)
      PLOT_BOTTOM - ((PLOT_BOTTOM - PLOT_TOP) * value / y_max.to_f)
    end

    def column_width
      (PLOT_RIGHT - PLOT_LEFT) / @labels.size.to_f
    end

    def grid_svg
      color = SvgRasterizer::AZUL_PAPYRUS
      horizontal = (0..y_max).step(step).map do |value|
        y = y_for(value).round(1)
        %(<line x1="#{PLOT_LEFT}" y1="#{y}" x2="#{PLOT_RIGHT}" y2="#{y}" stroke="##{color}" stroke-width="#{value.zero? ? 2 : 0.8}"/>) +
          SvgRasterizer.text(PLOT_LEFT - 10, y + 5, value, size: 14, color: SvgRasterizer::CINZA_ESCURO, anchor: "end")
      end
      frame = %(<rect x="#{PLOT_LEFT}" y="#{PLOT_TOP}" width="#{PLOT_RIGHT - PLOT_LEFT}" height="#{PLOT_BOTTOM - PLOT_TOP}" fill="none" stroke="##{color}" stroke-width="1.2"/>)
      axis = %(<text x="20" y="#{(PLOT_TOP + PLOT_BOTTOM) / 2}" text-anchor="middle" font-family="#{SvgRasterizer::FONT}" font-size="14" fill="##{SvgRasterizer::CINZA_ESCURO}" transform="rotate(-90 20 #{(PLOT_TOP + PLOT_BOTTOM) / 2})">Profissionais</text>)
      horizontal.join + frame + axis
    end

    def bars_svg
      bar_width = [ column_width * 0.55, 46 ].min
      @labels.each_index.map do |index|
        x = (PLOT_LEFT + (column_width * index) + ((column_width - bar_width) / 2)).round(1)
        base = 0
        rects = SECTORS.keys.filter_map do |sector|
          value = @series[sector][index]
          next if value.zero?

          top = y_for(base + value)
          rect = %(<rect x="#{x}" y="#{top.round(1)}" width="#{bar_width.round(1)}" height="#{(y_for(base) - top).round(1)}" fill="##{COLORS[sector]}"/>)
          base += value
          rect
        end
        total = totals[index]
        rects.join + (total.positive? ? SvgRasterizer.text((x + (bar_width / 2)).round(1), (y_for(total) - 7).round(1), total, size: 14, color: SvgRasterizer::AZUL_PAPYRUS, weight: "bold") : "")
      end.join
    end

    # Muitos meses: rótulo inclinado, e só um a cada N pra não encavalar.
    def x_labels_svg
      every = (@labels.size / 18.0).ceil
      rotate = @labels.size > 12
      @labels.each_with_index.filter_map do |label, index|
        next unless (index % every).zero?

        x = (PLOT_LEFT + (column_width * (index + 0.5))).round(1)
        y = PLOT_BOTTOM + 22
        transform = rotate ? %( transform="rotate(-45 #{x} #{y})") : ""
        anchor = rotate ? "end" : "middle"
        %(<text x="#{x}" y="#{y}" text-anchor="#{anchor}" font-family="#{SvgRasterizer::FONT}" font-size="13" fill="##{SvgRasterizer::CINZA_ESCURO}"#{transform}>#{label}</text>)
      end.join
    end

    def legend_svg
      present = SECTORS.select { |sector, _| @series[sector].any?(&:positive?) }
      x = (WIDTH - (present.size * 150)) / 2.0
      present.each_with_index.map do |(sector, label), index|
        left = x + (index * 150)
        %(<rect x="#{left}" y="#{HEIGHT - 32}" width="16" height="16" fill="##{COLORS[sector]}"/>) +
          SvgRasterizer.text(left + 24, HEIGHT - 19, label, size: 14, color: SvgRasterizer::CINZA_ESCURO, anchor: "start")
      end.join
    end
end
