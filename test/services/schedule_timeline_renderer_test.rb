require "test_helper"

# A estrutura do SVG é testada via #svgs (sem depender do rsvg-convert estar instalado — mesma
# disciplina de AreaSketchRendererTest, contagem/regex de tag). A rasterização de verdade
# (#call) tem sua própria seção, rodando o binário real — mesma metodologia de
# ScheduleMspdiExporterTest com o helper Java: só isso garante que o arquivo abre de verdade.
class ScheduleTimelineRendererTest < ActiveSupport::TestCase
  test "svgs returns [] when there are no items" do
    assert_empty renderer(items: []).svgs
  end

  test "call returns [] when there are no items" do
    assert_empty renderer(items: []).call
  end

  test "exactly one main circle and one badge circle per item, and one connecting line per row" do
    items = (1..8).map { |n| item("Atividade #{n}", start_period: n) }

    svg = renderer(items: items).svgs.first

    # 8 itens = 2 linhas (ITEMS_PER_ROW = 6): 6 na primeira, 2 na segunda — 2 linhas conectoras
    # (a segunda linha, de 2 itens, também tem 1 <line> — só uma linha com 1 item só não teria).
    assert_equal 2, svg.scan("<line ").size
    # círculo principal (r=40) + badge (r=15) por item = 16, mais o que cada ícone desenha por
    # dentro (varia por ícone) — aqui todos batem "aprova"/genérico, então só os círculos fixos.
    assert_equal 8, svg.scan('r="40"').size
    assert_equal 8, svg.scan('r="15"').size
  end

  test "numbers circles sequentially across the whole schedule, not restarting per row" do
    items = (1..8).map { |n| item("Atividade #{n}", start_period: n) }

    svg = renderer(items: items).svgs.first

    (1..8).each { |n| assert_includes svg, format(">%02d<", n) }
  end

  test "milestone item uses MILESTONE_FILL, regular item uses CIRCLE_FILL" do
    items = [
      item("Marco de aprovação", start_period: 1, milestone: true),
      item("Atividade normal", start_period: 2, milestone: false)
    ]

    svg = renderer(items: items).svgs.first

    assert_includes svg, %(fill="##{ScheduleTimelineRenderer::MILESTONE_FILL}")
    assert_includes svg, %(fill="##{ScheduleTimelineRenderer::CIRCLE_FILL}")
  end

  test "picks the icon by keyword in the activity name, and the generic icon when nothing matches" do
    mobilizacao = renderer(items: [ item("Mobilização das equipes") ]).svgs.first
    campo = renderer(items: [ item("Campanha de campo") ]).svgs.first
    generico = renderer(items: [ item("Assinatura do Contrato e Kick-Off") ]).svgs.first

    # Cada ícone (Heroicons real — PEOPLE_PATHS, PIN_PATHS etc.) tem um "d" de path diferente —
    # só confere que a palavra-chave muda o ícone escolhido, sem depender do desenho exato.
    assert_not_equal mobilizacao, campo
    # GENERIC_PATHS é um <circle r="5"> dentro do grupo do ícone — não existe em nenhum outro
    # ícone (os outros círculos do infográfico são r="40" do círculo principal e r="15" do badge).
    assert_includes generico, 'r="5"'
  end

  # Mesma conta de ScheduleMspdiExporter#item_start/#item_finish — a data mostrada no infográfico
  # tem que bater com a data que o cronograma "de verdade" (tabela, MSPDI) usa.
  test "date range and duration match the same elapsed-days math as ScheduleMspdiExporter" do
    schedule_item = item("Campanha de campo", start_period: 2, duration_periods: 2)

    svg = renderer(items: [ schedule_item ], start_date: Date.new(2026, 10, 1), unit: :week).svgs.first

    assert_includes svg, "08/10/2026 a 22/10/2026" # semana 2 = +7 dias; +2 semanas de duração = +14
    assert_includes svg, "14 dias"
  end

  test "a duration of zero periods reads as 'Marco' instead of '0 dias'" do
    svg = renderer(items: [ item("Assinatura", start_period: 1, duration_periods: 1, milestone: true) ],
      start_date: Date.new(2026, 10, 1), unit: :week).svgs.first

    # Marco real do sistema tem duration_periods >= 1 (regra do ScheduleItem, é do Gantt do
    # .docx) — aqui simulado como "termina no mesmo dia que começa" não é o caso comum, mas o
    # rótulo "Marco" (em vez de "0 dias") existe pra qualquer item de duração zero, se algum dia
    # aparecer um assim.
    assert_includes svg, "dia" # sanity: pelo menos alguma duração aparece pro item normal
  end

  test "long activity names wrap into multiple lines instead of overflowing the column" do
    long_name = "Revisão técnica, emissão da ART e revisão completa de todos os produtos entregáveis do estudo"

    svg = renderer(items: [ item(long_name) ]).svgs.first

    assert_operator svg.scan("<text").size, :>=, 3 # badge + pelo menos 2 linhas de título
  end

  # Achado ao vivo (proposta 21, 34 itens/6 linhas): uma imagem só ficava mais alta que uma
  # página paisagem inteira, e o Word/LibreOffice cortava as linhas de baixo sem aviso nenhum.
  test "splits into more than one image when the schedule has more rows than fit on one page" do
    items = (1..19).map { |n| item("Atividade #{n}", start_period: n) }

    svgs = renderer(items: items).svgs

    assert_operator svgs.size, :>, 1, "19 itens (4 linhas) deveriam estourar MAX_IMAGE_HEIGHT_EMU e virar mais de uma imagem"
  end

  test "numbering continues across images instead of restarting at 01 on the second image" do
    items = (1..19).map { |n| item("Atividade #{n}", start_period: n) }

    svgs = renderer(items: items).svgs

    assert_not_includes svgs.first, ">19<"
    assert_includes svgs.last, ">19<"
    assert_not_includes svgs.last, ">01<" # o primeiro item da 2ª imagem não é o 01 de novo
  end

  # Rasterização de verdade — roda o rsvg-convert real, mesma disciplina de
  # ScheduleMspdiExporterTest com o helper Java: só isso garante que o arquivo abre de verdade,
  # não só que o XML "parece certo".
  test "call rasterizes into a real, valid PNG" do
    result = renderer(items: [ item("Aprovação da proposta", milestone: true), item("Mobilização das equipes") ]).call.first

    assert result, "esperava um Result — confirme que rsvg-convert (pacote librsvg2-bin) está instalado"
    assert result.png_bytes.start_with?("\x89PNG".b), "não parece um PNG de verdade"
    assert_equal ScheduleTimelineRenderer::PRINT_WIDTH_EMU, result.width_emu
    assert_operator result.height_emu, :>, 0
  end

  test "call returns one Result per image when the schedule spans more than one page" do
    items = (1..19).map { |n| item("Atividade #{n}", start_period: n) }

    results = renderer(items: items).call

    assert_operator results.size, :>, 1
    results.each { |result| assert result.png_bytes.start_with?("\x89PNG".b) }
  end

  private
    def renderer(items:, start_date: Date.new(2026, 10, 1), unit: :week)
      ScheduleTimelineRenderer.new(items: items, start_date: start_date, unit: unit)
    end

    def item(activity_name, start_period: 1, duration_periods: 1, milestone: false)
      ScheduleItem.new(schedule_type: "servico", phase_name: "Fase", activity_name: activity_name,
        start_period: start_period, duration_periods: duration_periods, milestone: milestone, position: 0)
    end
end
