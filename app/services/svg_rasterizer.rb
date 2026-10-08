# SVG → PNG via `rsvg-convert` (pacote `librsvg2-bin`) pros gráficos que vão no .docx — o modelo só
# declara PNG/JPG (ver ScheduleTimelineRenderer, que tem a mesma conta própria desde antes).
require "open3"

module SvgRasterizer
  class Error < StandardError; end

  # Largura útil da página retrato (8504 dxa × 635 EMU/dxa).
  PORTRAIT_WIDTH_EMU = 8504 * 635

  # Paleta do Manual de Identidade Visual Papyrus (2018, pp. 27-28).
  AZUL_PAPYRUS = "064860"
  AZUL_MEDIO1 = "3E7283"
  AZUL_MEDIO2 = "759CA5"
  AZUL_MEDIO3 = "ADC5C8"
  BRANCO_PAPYRUS = "EBFCF4"
  CINZA_ESCURO = "666666"
  CINZA_LUZ = "EBEBEB"
  VERDE_BRASIL_ESCURO = "04AA96"
  AMARELO_BRASIL = "FFB92C"
  FONT = "Metropolis, Arial, sans-serif"

  module_function

  def png(svg_source)
    Tempfile.create([ "chart", ".svg" ]) do |input|
      input.write(svg_source)
      input.flush
      Tempfile.create([ "chart", ".png" ], binmode: true) do |output|
        _stdout, stderr, status = Open3.capture3("rsvg-convert", "-z", "2", "-o", output.path, input.path)
        raise Error, stderr.presence || "rsvg-convert falhou" unless status.success?

        File.binread(output.path)
      end
    end
  rescue Errno::ENOENT
    raise Error, "rsvg-convert não está instalado (pacote librsvg2-bin)"
  end

  def text(x, y, content, size:, color:, weight: nil, anchor: "middle")
    weight_attr = weight ? %( font-weight="#{weight}") : ""
    %(<text x="#{x}" y="#{y}" text-anchor="#{anchor}" font-family="#{FONT}" font-size="#{size}"#{weight_attr} fill="##{color}">#{CGI.escapeHTML(content.to_s)}</text>)
  end

  # Quebra por número de caracteres (a fonte é proporcional, mas a estimativa basta pra caixa).
  def wrap(content, max_chars)
    content.to_s.split.each_with_object([ +"" ]) do |word, lines|
      if lines.last.empty? then lines.last << word
      elsif lines.last.length + 1 + word.length <= max_chars then lines.last << " " << word
      else lines << word.dup
      end
    end.reject(&:empty?)
  end
end
