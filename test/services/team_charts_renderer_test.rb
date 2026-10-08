require "test_helper"

# Organograma e histograma da equipe (2026-10): só entram quando o cliente pede (ET/TR), cores do
# Manual de Identidade Visual Papyrus.
class TeamChartsRendererTest < ActiveSupport::TestCase
  Member = Proposal::TeamMember
  Item = Data.define(:phase_name, :activity_name, :start_period, :duration_periods)

  def members
    [
      Member.new(name: "Charlene Luz", sector: :diretoria, function: "Diretora de Negócios", man_hours: 0, field_days: 0),
      Member.new(name: "Pedro Skinner", sector: :gestao, function: "Coordenador de Projetos", man_hours: 100, field_days: 0),
      Member.new(name: "Ícaro Menezes", sector: :execucao, function: "Meio Biótico – Fauna", man_hours: 40, field_days: 5),
      Member.new(name: "Igor Andrade", sector: :execucao, function: "Meio Biótico – Fauna", man_hours: 40, field_days: 5),
      Member.new(name: "Rodrigo Moate", sector: :execucao, function: "Geoprocessamento", man_hours: 80, field_days: 0)
    ]
  end

  # Semanas a partir de 01/01/2027: campo em fevereiro, relatório em março, protocolo em abril.
  def items
    [
      Item.new(phase_name: "Diagnóstico", activity_name: "Campanha de campo", start_period: 6, duration_periods: 2),
      Item.new(phase_name: "Diagnóstico", activity_name: "Elaboração do relatório", start_period: 10, duration_periods: 3),
      Item.new(phase_name: "Licenciamento", activity_name: "Protocolo no órgão", start_period: 14, duration_periods: 2)
    ]
  end

  test "organograma: diretoria e gestão em caixas próprias, execução agrupada pela função" do
    svg = TeamOrganogramRenderer.new(members: members).svg

    assert_includes svg, ">Charlene Luz<"
    assert_includes svg, ">Pedro Skinner<"
    assert_equal 1, svg.scan(">Meio Biótico – Fauna<").size, "uma caixa por função, com as duas pessoas dentro"
    assert_includes svg, ">Ícaro Menezes<"
    assert_includes svg, ">Igor Andrade<"
    assert_includes svg, "##{SvgRasterizer::AZUL_PAPYRUS}"
  end

  test "organograma sem equipe não desenha nada" do
    assert_nil TeamOrganogramRenderer.new(members: []).call
  end

  test "histograma: meses do cronograma; diretoria/gestão o projeto todo, campo e elaboração nos seus meses" do
    histogram = TeamHistogramRenderer.from_schedule(members: members, items: items, start_date: Date.new(2027, 1, 1))

    assert_equal %w[jan/27 fev/27 mar/27 abr/27], histogram.labels
    assert_equal [ 1, 1, 1, 1 ], histogram.series[:diretoria]
    assert_equal [ 1, 1, 1, 1 ], histogram.series[:gestao]
    # Fauna (campo + HH): fevereiro (campo) e março (relatório); geo (só HH): março. Protocolo não conta.
    assert_equal [ 0, 2, 3, 0 ], histogram.series[:execucao]
  end

  test "histograma: a alocação passada pela IA vale pra quem ela citou" do
    histogram = TeamHistogramRenderer.from_schedule(members: members, items: items, start_date: Date.new(2027, 1, 1),
      allocations: [ "Rodrigo Moate | 1-2, 9", "ícaro menezes | 4" ])

    # Rodrigo em jan/fev (mês 9 não existe e é ignorado); Ícaro só em abril; Igor segue a regra.
    assert_equal [ 1, 2, 1, 1 ], histogram.series[:execucao]
  end

  test "histograma sem cronograma não existe" do
    assert_nil TeamHistogramRenderer.from_schedule(members: members, items: [], start_date: Date.new(2027, 1, 1))
  end

  test "rasteriza os dois pra PNG" do
    png = TeamOrganogramRenderer.new(members: members).call
    assert png.png_bytes.start_with?("\x89PNG".b)
    assert_equal SvgRasterizer::PORTRAIT_WIDTH_EMU, png.width_emu

    histogram = TeamHistogramRenderer.from_schedule(members: members, items: items, start_date: Date.new(2027, 1, 1)).call
    assert histogram.png_bytes.start_with?("\x89PNG".b)
  end
end
