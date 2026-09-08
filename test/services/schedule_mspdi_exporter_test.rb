require "test_helper"
require "mpxj"

# Testes de ponta a ponta de verdade (não mocka o helper Java) — rodam `java` de verdade e releem
# o MSPDI gerado com o próprio MPXJ::Reader da gem, mesma metodologia usada pra verificar o
# ScheduleToMspdi.java manualmente (CLAUDE.md seção 8). Mais lentos que um teste unitário comum,
# mas é a única forma de garantir que o arquivo abre de verdade — XML "parece certo" não basta.
class ScheduleMspdiExporterTest < ActiveSupport::TestCase
  test "returns nil when there are no items" do
    assert_nil ScheduleMspdiExporter.new(items: [], start_date: Date.new(2026, 10, 1), unit: :week, name: "Vazio").call
  end

  test "exports phases and activities with correct hierarchy, dates and milestones for weekly items" do
    items = [
      item(phase: "Mobilização", activity: "Assinatura do Contrato", start: 1, duration: 1, milestone: true),
      item(phase: "Mobilização", activity: "Kick-off", start: 1, duration: 1),
      item(phase: "Diagnóstico", activity: "Campo", start: 2, duration: 3)
    ]

    bytes = ScheduleMspdiExporter.new(items: items, start_date: Date.new(2026, 10, 1), unit: :week, name: "Cronograma Teste").call
    tasks = read_back(bytes)

    assert_equal [ "Mobilização", "Assinatura do Contrato", "Kick-off", "Diagnóstico", "Campo" ], tasks.map(&:name)

    mobilizacao = tasks.find { |t| t.name == "Mobilização" }
    assert_equal 1, mobilizacao.outline_level
    assert_equal Date.new(2026, 10, 1), mobilizacao.start.to_date

    assinatura = tasks.find { |t| t.name == "Assinatura do Contrato" }
    assert_equal 2, assinatura.outline_level
    assert assinatura.milestone
    assert_equal Date.new(2026, 10, 1), assinatura.start.to_date
    assert_equal Date.new(2026, 10, 8), assinatura.finish.to_date

    campo = tasks.find { |t| t.name == "Campo" }
    assert_not campo.milestone
    assert_equal Date.new(2026, 10, 8), campo.start.to_date # semana 2 = start_date + 7 dias
    assert_equal Date.new(2026, 10, 29), campo.finish.to_date # 3 semanas de duração
  end

  test "uses calendar months instead of weeks when unit is :month" do
    items = [ item(phase: "Implantação", activity: "Obras Civis", start: 1, duration: 6) ]

    bytes = ScheduleMspdiExporter.new(items: items, start_date: Date.new(2026, 1, 1), unit: :month, name: "Implantação").call
    tasks = read_back(bytes)

    obras = tasks.find { |t| t.name == "Obras Civis" }
    assert_equal Date.new(2026, 1, 1), obras.start.to_date
    assert_equal Date.new(2026, 7, 1), obras.finish.to_date # 6 meses corridos
  end

  test "rolls the phase (summary) task up to cover the span of its own activities" do
    items = [
      item(phase: "Fase única", activity: "Primeira", start: 3, duration: 1),
      item(phase: "Fase única", activity: "Segunda", start: 1, duration: 2)
    ]

    bytes = ScheduleMspdiExporter.new(items: items, start_date: Date.new(2026, 10, 1), unit: :week, name: "Rollup").call
    fase = read_back(bytes).find { |t| t.name == "Fase única" }

    assert_equal Date.new(2026, 10, 1), fase.start.to_date # início da atividade mais cedo (Segunda, semana 1)
    assert_equal Date.new(2026, 10, 22), fase.finish.to_date # fim da atividade mais tarde (Primeira, semana 3)
  end

  private
    def item(phase:, activity:, start:, duration:, milestone: false)
      ScheduleItem.new(schedule_type: "servico", phase_name: phase, activity_name: activity,
        start_period: start, duration_periods: duration, milestone: milestone, position: 0)
    end

    def read_back(bytes)
      Tempfile.create([ "schedule", ".xml" ], binmode: true) do |tmp|
        tmp.write(bytes)
        tmp.flush
        return MPXJ::Reader.read(tmp.path).all_tasks.reject { |t| t.name.nil? }
      end
    end
end
