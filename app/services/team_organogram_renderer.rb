# Organograma da equipe da proposta (2026-10, pedido da Papyrus: só quando o cliente pede no ET/TR).
# Diretoria → Gestão → Execução, a execução agrupada pela FUNÇÃO do Quadro de Equipe (o macrogrupo:
# "Meio Biótico – Fauna", "Geoprocessamento"…), com os nomes dentro de cada caixa. Mesmas pessoas e
# funções do quadro (Proposal#team_members_for_charts), cores do Manual de Identidade Visual.
class TeamOrganogramRenderer
  Result = Data.define(:png_bytes, :width_emu, :height_emu)

  WIDTH = 1000
  MARGIN = 24
  PERSON_BOX_WIDTH = 250
  GROUP_BOX_WIDTH = 178
  GROUPS_PER_ROW = 5
  BOX_GAP = 18
  LEVEL_GAP = 46
  LINE_HEIGHT = 17
  SPINE_X = 8

  LEVEL_COLORS = { diretoria: SvgRasterizer::AZUL_PAPYRUS, gestao: SvgRasterizer::AZUL_MEDIO1 }.freeze

  Box = Data.define(:x, :y, :width, :height, :svg) do
    def center_x = x + (width / 2.0)
    def bottom = y + height
  end

  def initialize(members:)
    @members = members
  end

  def call
    return nil if @members.empty?

    svg_source = svg
    Result.new(png_bytes: SvgRasterizer.png(svg_source), width_emu: SvgRasterizer::PORTRAIT_WIDTH_EMU,
      height_emu: (SvgRasterizer::PORTRAIT_WIDTH_EMU * @height / WIDTH.to_f).round)
  end

  def svg
    @levels = []
    y = MARGIN
    %i[diretoria gestao].each do |sector|
      people = @members.select { |member| member.sector == sector }
      next if people.empty?

      row = person_row(people, sector, y)
      @levels << [ row ]
      y = row.map(&:bottom).max + LEVEL_GAP
    end

    groups = @members.select { |member| member.sector == :execucao }.group_by(&:function)
    unless groups.empty?
      rows = groups.to_a.each_slice(GROUPS_PER_ROW).map do |slice|
        row = group_row(slice, y)
        y = row.map(&:bottom).max + LEVEL_GAP
        row
      end
      @levels << rows
    end

    @height = (y - LEVEL_GAP + MARGIN).round
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{@height}" viewBox="0 0 #{WIDTH} #{@height}">
        <rect width="#{WIDTH}" height="#{@height}" fill="#FFFFFF"/>
        #{connectors_svg}
        #{@levels.flatten.map(&:svg).join("\n")}
      </svg>
    SVG
  end

  private
    def person_row(people, sector, top)
      boxes = people.map do |member|
        name_lines = SvgRasterizer.wrap(member.name, 26)
        function_lines = SvgRasterizer.wrap(member.function, 32)
        height = 20 + (name_lines.size * LINE_HEIGHT) + (function_lines.size * (LINE_HEIGHT - 2)) + 6
        [ member, name_lines, function_lines, height ]
      end
      height = boxes.map(&:last).max
      xs = centered_xs(boxes.size, PERSON_BOX_WIDTH)

      boxes.each_with_index.map do |(_member, name_lines, function_lines, _), index|
        x = xs[index]
        center = x + (PERSON_BOX_WIDTH / 2.0)
        texts = name_lines.each_with_index.map { |line, i| SvgRasterizer.text(center, top + 26 + (i * LINE_HEIGHT), line, size: 15, color: "FFFFFF", weight: "bold") }
        offset = top + 26 + (name_lines.size * LINE_HEIGHT)
        texts += function_lines.each_with_index.map { |line, i| SvgRasterizer.text(center, offset + (i * (LINE_HEIGHT - 2)), line, size: 12, color: SvgRasterizer::BRANCO_PAPYRUS) }
        svg = %(<rect x="#{x}" y="#{top}" width="#{PERSON_BOX_WIDTH}" height="#{height}" rx="8" fill="##{LEVEL_COLORS.fetch(sector)}"/>) + texts.join
        Box.new(x: x, y: top, width: PERSON_BOX_WIDTH, height: height, svg: svg)
      end
    end

    def group_row(groups, top)
      prepared = groups.map do |function, members|
        title_lines = SvgRasterizer.wrap(function.presence || "Equipe técnica", 22)
        name_lines = members.flat_map { |member| SvgRasterizer.wrap(member.name, 24) }
        header = 12 + (title_lines.size * LINE_HEIGHT)
        [ title_lines, name_lines, header, header + 12 + (name_lines.size * LINE_HEIGHT) ]
      end
      height = prepared.map(&:last).max
      header_height = prepared.map { |p| p[2] }.max
      xs = centered_xs(prepared.size, GROUP_BOX_WIDTH)

      prepared.each_with_index.map do |(title_lines, name_lines, _, _), index|
        x = xs[index]
        center = x + (GROUP_BOX_WIDTH / 2.0)
        title_top = top + ((header_height - (title_lines.size * LINE_HEIGHT)) / 2.0) + 13
        texts = title_lines.each_with_index.map { |line, i| SvgRasterizer.text(center, title_top + (i * LINE_HEIGHT), line, size: 13, color: "FFFFFF", weight: "bold") }
        texts += name_lines.each_with_index.map { |line, i| SvgRasterizer.text(center, top + header_height + 20 + (i * LINE_HEIGHT), line, size: 13, color: SvgRasterizer::AZUL_PAPYRUS) }
        svg = %(<rect x="#{x}" y="#{top}" width="#{GROUP_BOX_WIDTH}" height="#{height}" rx="8" fill="##{SvgRasterizer::BRANCO_PAPYRUS}" stroke="##{SvgRasterizer::AZUL_MEDIO2}" stroke-width="1.5"/>) +
          %(<path d="M#{x} #{top + header_height} V#{top + 8} Q#{x} #{top} #{x + 8} #{top} H#{x + GROUP_BOX_WIDTH - 8} Q#{x + GROUP_BOX_WIDTH} #{top} #{x + GROUP_BOX_WIDTH} #{top + 8} V#{top + header_height} Z" fill="##{SvgRasterizer::VERDE_BRASIL_ESCURO}"/>) +
          texts.join
        Box.new(x: x, y: top, width: GROUP_BOX_WIDTH, height: height, svg: svg)
      end
    end

    def centered_xs(count, width)
      total = (count * width) + ((count - 1) * BOX_GAP)
      start = (WIDTH - total) / 2.0
      Array.new(count) { |i| start + (i * (width + BOX_GAP)) }
    end

    # Linhas em ângulo reto: cada nível desce até uma barra a meio caminho e dela pra cada caixa de
    # baixo. Execução em mais de uma fileira: as fileiras seguintes ligam por uma coluna na margem
    # esquerda (passar pelo meio cruzaria as caixas da fileira de cima).
    def connectors_svg
      @levels.each_cons(2).flat_map do |upper, lower|
        parents = upper.last
        lower.each_with_index.flat_map do |row, index|
          mid = row.first.y - (LEVEL_GAP / 2.0)
          centers = row.map(&:center_x)
          lines = row.map { |box| line(box.center_x, mid, box.center_x, box.y) }
          if index.zero?
            lines += parents.map { |box| line(box.center_x, box.bottom, box.center_x, mid) }
            span = centers + parents.map(&:center_x)
            span << SPINE_X if lower.size > 1
            lines << line(span.min, mid, span.max, mid)
            @spine_top = mid
          else
            lines << line(SPINE_X, @spine_top, SPINE_X, mid)
            lines << line(SPINE_X, mid, centers.max, mid)
          end
          lines
        end
      end.join("\n")
    end

    def line(x1, y1, x2, y2)
      %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="##{SvgRasterizer::AZUL_PAPYRUS}" stroke-width="2"/>)
    end
end
