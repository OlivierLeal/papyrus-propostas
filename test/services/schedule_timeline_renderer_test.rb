require "test_helper"

# A estrutura do SVG é testada via #svgs (sem depender do rsvg-convert estar instalado — mesma
# disciplina de AreaSketchRendererTest, contagem/regex de tag). A rasterização de verdade
# (#call) tem sua própria seção, rodando o binário real — mesma metodologia de
# ScheduleMspdiExporterTest com o helper Java: só isso garante que o arquivo abre de verdade.
#
# Cada CÍRCULO é uma FASE, não uma atividade (2026-09, pedido do cliente: infográfico "gigante"
# com 34 círculos em 3 imagens → resumo executivo de ~6-10 fases numa imagem só).
class ScheduleTimelineRendererTest < ActiveSupport::TestCase
  test "svgs returns [] when there are no items" do
    assert_empty renderer(items: []).svgs
  end

  test "call returns [] when there are no items" do
    assert_empty renderer(items: []).call
  end

  test "one circle per PHASE, not per activity — activities in the same phase collapse into one" do
    items = [
      activity("Mobilização", "Kick-off", start: 1),
      activity("Mobilização", "Levantamento", start: 2),
      activity("Diagnóstico", "Campo", start: 3),
      activity("Diagnóstico", "Relatório", start: 5),
      activity("Licenciamento", "Protocolo", start: 8)
    ]

    svg = renderer(items: items).svgs.first

    assert_equal 3, svg.scan('r="40"').size # 3 fases, não 5 atividades
    assert_equal 3, svg.scan('r="15"').size
    assert_includes svg, ">Mobilização<"
    assert_includes svg, ">Diagnóstico<"
    assert_includes svg, ">Licenciamento<"
  end

  test "non-contiguous activities in the same phase collapse into one phase circle" do
    items = [
      activity("Mobilização", "Kick-off", start: 1),
      activity("Diagnóstico", "Campo", start: 3),
      activity("Mobilização", "Reunião de Alinhamento", start: 5)
    ]

    svg = renderer(items: items).svgs.first

    assert_equal 2, svg.scan('r="40"').size # 2 fases únicas, não 3 fragmentos
    assert_includes svg, ">Mobilização<"
    assert_includes svg, ">Diagnóstico<"
  end

  test "numbers the phase circles 01..N sequentially" do
    items = (1..4).flat_map { |n| [ activity("Fase #{n}", "A", start: n), activity("Fase #{n}", "B", start: n) ] }

    svg = renderer(items: items).svgs.first

    (1..4).each { |n| assert_includes svg, format(">%02d<", n) }
    assert_not_includes svg, ">05<"
  end

  test "ring color follows the gradient by phase position" do
    items = (1..3).map { |n| activity("Fase #{n}", "A", start: n) }

    svg = renderer(items: items).svgs.first

    assert_equal 3, svg.scan(/stroke="#[0-9A-F]{6}" stroke-width="4"/).size
  end

  test "picks the icon by keyword in the PHASE name, generic when nothing matches" do
    mobilizacao = renderer(items: [ activity("Mobilização das equipes", "x", start: 1) ]).svgs.first
    campo = renderer(items: [ activity("Campanha de campo", "x", start: 1) ]).svgs.first
    generico = renderer(items: [ activity("Assinatura do Contrato e Kick-Off", "x", start: 1) ]).svgs.first

    assert_not_equal mobilizacao, campo
    # GENERIC_PATHS é um <circle r="5"> dentro do grupo do ícone.
    assert_includes generico, 'r="5"'
  end

  # Só a duração em dias, sem nenhuma data — a conta bate com ScheduleMspdiExporter#item_start/
  # #item_finish sobre o span da fase (início da 1ª atividade → fim da última).
  test "shows only the duration in days of the whole phase, no dates" do
    items = [ activity("Diagnóstico", "Campo", start: 2, duration: 2) ]

    svg = renderer(items: items, start_date: Date.new(2026, 10, 1), unit: :week).svgs.first

    assert_includes svg, "14 dias" # 2 semanas
    assert_no_match(%r{\d{2}/\d{2}/\d{4}}, svg)
  end

  test "a phase whose activities are all milestones shows '-' instead of a duration" do
    items = [
      activity("Emissão da Licença", "LP", start: 1, milestone: true),
      activity("Execução", "Obra", start: 2, duration: 3, milestone: false)
    ]

    svg = renderer(items: items, start_date: Date.new(2026, 10, 1), unit: :week).svgs.first

    assert_includes svg, ">-<"
    assert_includes svg, "dias" # a fase de execução tem duração
  end

  test "long phase names wrap into multiple lines instead of overflowing the column" do
    long_name = "Elaboração dos Estudos Ambientais, Consolidação dos Diagnósticos e Revisão Técnica Completa"

    svg = renderer(items: [ activity(long_name, "x", start: 1) ]).svgs.first

    assert_operator svg.scan("<text").size, :>=, 3
  end

  # 2026-09, pedido do consultor: "consegue colocar a frase toda?" — um título que precisasse de
  # mais de 3 linhas saía cortado com "…" antes desta correção.
  test "a very long phase name never gets truncated with an ellipsis, however many lines it needs" do
    long_name = "Elaboração dos Estudos Ambientais, Consolidação dos Diagnósticos, Revisão Técnica " \
      "Completa dos Relatórios Finais e Apresentação dos Resultados ao Órgão Ambiental Licenciador"

    svg = renderer(items: [ activity(long_name, "x", start: 1) ]).svgs.first

    refute_includes svg, "…"
    assert_includes svg, "Ambiental Licenciador" # a última palavra da frase aparece de verdade
  end

  # A linha de círculos inteira cresce pro tamanho do MAIOR título dela — sem isso, um título
  # curto do lado de um título longo desalinharia o sublinhado/duração entre os dois.
  test "a taller title makes the whole row taller without misaligning its shorter neighbor's underline" do
    items = [
      activity("Fase Curta", "a", start: 1, duration: 1),
      activity("Fase com um Nome Bem Mais Longo do que a Vizinha Ao Lado Dela Mesma", "b", start: 2, duration: 1)
    ]

    svg = renderer(items: items).svgs.first
    underline_ys = svg.scan(/<line x1="[\d.]+" y1="([\d.]+)" x2="[\d.]+" y2="[\d.]+" stroke="#[0-9A-Fa-f]{6}" stroke-width="3"/).flatten

    assert_equal 2, underline_ys.size
    assert_equal underline_ys.first, underline_ys.last
  end

  # Cronograma sem nenhum título comprido continua com a mesma altura de sempre — a linha só
  # cresce quando o CONTEÚDO precisa, não incondicionalmente.
  test "a row with only short titles keeps the original, compact height" do
    short_svg = renderer(items: [ activity("Fase A", "x", start: 1) ]).svgs.first
    long_svg = renderer(items: [ activity("Fase com um Nome Consideravelmente Mais Longo do que Fase A", "x", start: 1) ]).svgs.first

    short_height = short_svg[/viewBox="0 0 \d+ (\d+)"/, 1].to_i
    long_height = long_svg[/viewBox="0 0 \d+ (\d+)"/, 1].to_i

    assert_operator long_height, :>, short_height
  end

  test "a schedule with many activities but few phases still fits in a single image" do
    # 6 fases contíguas × 5 atividades = 30 atividades, mas só 6 círculos.
    items = (1..6).flat_map do |phase|
      (1..5).map { |a| activity("Fase #{phase}", "Atividade #{phase}.#{a}", start: ((phase - 1) * 5) + a) }
    end

    assert_equal 1, renderer(items: items).svgs.size
  end

  # Rede de segurança: um número irreal de FASES ainda quebra em várias imagens (Word/LibreOffice
  # cortam sem aviso uma imagem mais alta que a página).
  test "splits into more than one image only when there are too many phases for one page" do
    items = (1..20).map { |n| activity("Fase #{n}", "A", start: n) }

    svgs = renderer(items: items).svgs

    assert_operator svgs.size, :>, 1
    assert_not_includes svgs.first, ">20<"
    assert_includes svgs.last, ">20<"
    assert_not_includes svgs.last, ">01<"
  end

  # key_points: os ≤6 marcos que a IA elege do cronograma_servico (2026-09) — quando presentes,
  # cada marco vira um círculo e a duração abaixo dele é o trecho do marco anterior até ele.
  test "with key_points, renders one circle per elected marco named by the marco" do
    items = (1..8).map { |n| activity("Fase #{n}", "Atividade #{n}", start: n) }
    key_points = [ key_point("Assinatura do contrato", 1), key_point("Protocolo no órgão", 4),
      key_point("Emissão da LP", 7), key_point("Entrega final", 8) ]

    svg = renderer(items: items, key_points: key_points).svgs.first

    assert_equal 4, svg.scan('r="40"').size
    assert_includes svg, ">Assinatura do contrato<"
    assert_includes svg, ">Protocolo no órgão<"
    assert_includes svg, ">Emissão da LP<"
    assert_includes svg, ">Entrega final<"
  end

  test "the duration under each key_point is the span from the previous marco to it" do
    items = (1..10).map { |n| activity("Fase #{n}", "A", start: n) }
    key_points = [ key_point("Início", 3), key_point("Meio", 6) ]

    svg = renderer(items: items, key_points: key_points, unit: :week).svgs.first

    assert_includes svg, "14 dias" # marco 1: semanas 1..3 → 2 semanas
    assert_includes svg, "21 dias" # marco 2: semanas 3..6 → 3 semanas
  end

  test "a key_point at the very start of the schedule shows '-' instead of a fake span" do
    items = (1..5).map { |n| activity("Fase #{n}", "A", start: n) }
    key_points = [ key_point("Assinatura", 1), key_point("Fim", 5) ]

    svg = renderer(items: items, key_points: key_points).svgs.first

    assert_includes svg, ">-<"
  end

  test "key_points are capped at 6 circles" do
    items = (1..12).map { |n| activity("Fase #{n}", "A", start: n) }
    key_points = (1..8).map { |n| key_point("Marco #{n}", n) }

    svg = renderer(items: items, key_points: key_points).svgs.first

    assert_equal 6, svg.scan('r="40"').size
    assert_equal 1, renderer(items: items, key_points: key_points).svgs.size
  end

  test "a key_point period past the end of the schedule is clamped, never a negative span" do
    items = (1..4).map { |n| activity("Fase #{n}", "A", start: n) } # cronograma termina na semana 5
    key_points = [ key_point("Início", 2), key_point("Muito depois", 99) ]

    svg = renderer(items: items, key_points: key_points, unit: :week).svgs.first

    assert_equal 2, svg.scan('r="40"').size
    assert_includes svg, "21 dias" # marco 2: semana 2 → semana 5 (clampado), 3 semanas
    assert_no_match(/-\d+ dias/, svg)
  end

  test "empty key_points falls back to the per-phase summary" do
    items = [ activity("Mobilização", "Kick-off", start: 1), activity("Mobilização", "Levantamento", start: 2),
      activity("Diagnóstico", "Campo", start: 3) ]

    svg = renderer(items: items, key_points: []).svgs.first

    assert_equal 2, svg.scan('r="40"').size # 2 fases, comportamento de sempre
  end

  test "call rasterizes into a real, valid PNG" do
    items = [ activity("Mobilização", "Kick-off", start: 1), activity("Diagnóstico", "Campo", start: 2) ]
    result = renderer(items: items).call.first

    assert result, "esperava um Result — confirme que rsvg-convert (pacote librsvg2-bin) está instalado"
    assert result.png_bytes.start_with?("\x89PNG".b), "não parece um PNG de verdade"
    assert_equal ScheduleTimelineRenderer::PRINT_WIDTH_EMU, result.width_emu
    assert_operator result.height_emu, :>, 0
  end

  private
    def renderer(items:, start_date: Date.new(2026, 10, 1), unit: :week, key_points: [])
      ScheduleTimelineRenderer.new(items: items, start_date: start_date, unit: unit, key_points: key_points)
    end

    def activity(phase, name, start: 1, duration: 1, milestone: false)
      ScheduleItem.new(schedule_type: "servico", phase_name: phase, activity_name: name,
        start_period: start, duration_periods: duration, milestone: milestone, position: 0)
    end

    def key_point(nome, periodo)
      { "nome" => nome, "periodo" => periodo }
    end
end
