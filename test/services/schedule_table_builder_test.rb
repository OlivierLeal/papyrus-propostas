require "test_helper"

class ScheduleTableBuilderTest < ActiveSupport::TestCase
  NS = { "w" => "http://schemas.openxmlformats.org/wordprocessingml/2006/main" }.freeze

  test "returns an empty string when there are no items" do
    assert_equal "", ScheduleTableBuilder.new([], start_date: Date.new(2026, 9, 1), unit: :week).build_xml
  end

  # Achado ao vivo: um cronograma de 104 semanas (a própria IA sugeriu, monitoramento de 2 anos)
  # deixava cada coluna tão estreita que o Word/LibreOffice quebrava "Sem 1"/"Setembro 2026" letra
  # por letra, empilhadas — ilegível. Gira o texto do cabeçalho 90° nesse caso. 24 semanas ainda
  # cabem 1 por coluna (abaixo do limiar de consolidação), mas cada uma já fica estreita demais
  # pra ficar horizontal.
  test "rotates the period header text when there are enough periods to make each column too narrow" do
    items = [ item(phase: "F", activity: "A", start: 1, duration: 24) ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    period_header = doc.xpath("(//w:tr)[2]/w:tc", NS)[2]

    assert_equal "btLr", period_header.at_xpath(".//w:textDirection", NS)["w:val"]
  end

  # O rótulo de GRUPO (mês/ano) só gira se o próprio grupo (largura = period_width × span) também
  # ficar estreito demais — um grupo de vários períodos juntos costuma continuar largo o
  # suficiente mesmo com a coluna individual apertada. Começando em dezembro, o primeiro grupo
  # (só "Dezembro", span 1) fica tão estreito quanto uma coluna sozinha; os seguintes (um ano
  # inteiro cada) ficam bem mais largos e continuam horizontais.
  test "rotates a single-period group header too, but not a wider multi-period one" do
    items = [ item(phase: "F", activity: "A", start: 1, duration: 24) ]

    doc = build_doc(items, start_date: Date.new(2026, 12, 1), unit: :month)
    group_headers = doc.xpath("(//w:tr)[1]/w:tc", NS)[2..]

    assert_equal "2026", group_headers[0].xpath(".//w:t", NS).text # só dezembro nesse ano
    assert_equal "btLr", group_headers[0].at_xpath(".//w:textDirection", NS)["w:val"]
    assert_nil group_headers[1].at_xpath(".//w:textDirection", NS) # ano inteiro seguinte, bem mais largo
  end

  test "keeps the header text horizontal for a normal-sized schedule (like the real reference example)" do
    items = [ item(phase: "F", activity: "A", start: 1, duration: 6) ] # bem abaixo do limiar de rotação

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    period_header = doc.xpath("(//w:tr)[2]/w:tc", NS)[2]

    assert_nil period_header.at_xpath(".//w:textDirection", NS)
  end

  # Achado ao vivo: mesmo o texto GIRADO some por completo abaixo de ~300dxa (o LibreOffice
  # precisa de uma largura mínima até pra texto vertical — a "altura de linha" da fonte vira a
  # dimensão horizontal depois do giro). Um cronograma de 104 semanas (2 anos, a própria IA
  # sugeriu) não cabe 1 semana por coluna de jeito nenhum — cada coluna passa a representar um
  # BLOCO de semanas ("Sem 1-4"), nunca menos que MIN_COLUMN_WIDTH.
  test "consolidates periods into wider buckets when there are too many to fit individually, even rotated" do
    items = [ item(phase: "F", activity: "A", start: 1, duration: 104) ]

    doc = build_doc(items, start_date: Date.new(2026, 10, 1), unit: :week)
    period_cells = doc.xpath("(//w:tr)[2]/w:tc", NS)[2..]

    assert_operator period_cells.size, :<, 104 # colunas consolidadas, não 1 por semana
    assert_match(/\ASem \d+-\d+\z/, period_cells.first.xpath(".//w:t", NS).text)

    widths = period_cells.map { |tc| tc.at_xpath(".//w:tcW", NS)["w:w"].to_i }
    assert widths.all? { |w| w >= ScheduleTableBuilder::MIN_COLUMN_WIDTH }
  end

  test "maps an activity's bar onto the consolidated buckets its raw period range falls into" do
    # 104 semanas força bucket_size 4 (ver MIN_COLUMN_WIDTH/max_display_periods) — uma atividade
    # nas semanas 5 a 8 (bucket 2, 1-based) tem que colorir só a 2ª coluna consolidada.
    items = [ item(phase: "F", activity: "A", start: 5, duration: 4), item(phase: "F", activity: "B", start: 1, duration: 104) ]

    doc = build_doc(items, start_date: Date.new(2026, 10, 1), unit: :week)
    activity_row = doc.xpath("//w:tr", NS)[3] # linha da fase (2), depois a atividade "A" (3)
    fills = activity_row.xpath("w:tc", NS)[2..].map { |tc| tc.at_xpath(".//w:shd", NS)&.[]("w:fill") }

    assert_equal [ nil, "2E75B6" ] + Array.new(fills.size - 2, nil), fills
  end

  test "builds a well-formed <w:tbl> with 2 fixed columns plus one per period" do
    items = [ item(phase: "Mobilização", activity: "Contrato", start: 1, duration: 3) ]

    doc = build_doc(items, start_date: Date.new(2026, 9, 1), unit: :week)

    grid_cols = doc.xpath("//w:tblGrid/w:gridCol", NS)
    assert_equal 5, grid_cols.size # ID + Fase/Atividade + 3 semanas
  end

  test "week grouping puts each week's start date into the right calendar month, with gridSpan matching the run length" do
    # 1/set/2026 é terça — semanas de 7 em 7 dias a partir daí: semanas 1-5 começam em setembro
    # (a de nº 5 começa em 29/set), só a semana 6 (06/out) já cai em outubro.
    items = [ item(phase: "Mobilização", activity: "X", start: 1, duration: 6) ]

    doc = build_doc(items, start_date: Date.new(2026, 9, 1), unit: :week)

    group_cells = doc.xpath("(//w:tr)[1]/w:tc", NS)[2..]
    labels = group_cells.map { |tc| tc.xpath(".//w:t", NS).text }
    spans = group_cells.map { |tc| (tc.at_xpath(".//w:gridSpan", NS)&.[]("w:val") || "1").to_i }

    assert_equal [ "Setembro 2026", "Outubro 2026" ], labels
    assert_equal [ 5, 1 ], spans
  end

  test "month grouping puts each month into the right calendar year" do
    items = [ item(phase: "Construção", activity: "Obra", start: 1, duration: 14) ]

    doc = build_doc(items, start_date: Date.new(2026, 11, 1), unit: :month)

    group_cells = doc.xpath("(//w:tr)[1]/w:tc", NS)[2..]
    labels = group_cells.map { |tc| tc.xpath(".//w:t", NS).text }
    spans = group_cells.map { |tc| (tc.at_xpath(".//w:gridSpan", NS)&.[]("w:val") || "1").to_i }

    assert_equal [ "2026", "2027" ], labels
    assert_equal [ 2, 12 ], spans
  end

  test "period header row (2nd row) labels each column Sem N for weeks and Mês N for months" do
    week_doc = build_doc([ item(phase: "F", activity: "A", start: 1, duration: 2) ], start_date: Date.new(2026, 1, 1), unit: :week)
    month_doc = build_doc([ item(phase: "F", activity: "A", start: 1, duration: 2) ], start_date: Date.new(2026, 1, 1), unit: :month)

    week_labels = week_doc.xpath("(//w:tr)[2]/w:tc", NS)[2..].map { |tc| tc.xpath(".//w:t", NS).text }
    month_labels = month_doc.xpath("(//w:tr)[2]/w:tc", NS)[2..].map { |tc| tc.xpath(".//w:t", NS).text }

    assert_equal [ "Sem 1", "Sem 2" ], week_labels
    assert_equal [ "Mês 1", "Mês 2" ], month_labels
  end

  test "emits a phase row (fundo D9E1F2, sem barra) only when the phase changes between consecutive items" do
    items = [
      item(phase: "Mobilização", activity: "A", start: 1, duration: 1),
      item(phase: "Mobilização", activity: "B", start: 2, duration: 1),
      item(phase: "Execução", activity: "C", start: 3, duration: 1)
    ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    data_rows = doc.xpath("//w:tr", NS)[2..] # pula as 2 linhas de cabeçalho

    # 2 fases + 3 atividades = 5 linhas de dado
    assert_equal 5, data_rows.size

    phase_row_1 = data_rows[0]
    assert_equal "1.0", phase_row_1.xpath("w:tc[1]//w:t", NS).text
    assert_equal "Mobilização", phase_row_1.xpath("w:tc[2]//w:t", NS).text
    assert_equal "D9E1F2", phase_row_1.xpath("w:tc[3]//w:shd", NS).first["w:fill"]

    phase_row_2 = data_rows[3]
    assert_equal "2.0", phase_row_2.xpath("w:tc[1]//w:t", NS).text
    assert_equal "Execução", phase_row_2.xpath("w:tc[2]//w:t", NS).text
  end

  test "numbers activity rows as fase.atividade, restarting the activity counter for each new phase" do
    items = [
      item(phase: "Mobilização", activity: "A", start: 1, duration: 1),
      item(phase: "Mobilização", activity: "B", start: 2, duration: 1),
      item(phase: "Execução", activity: "C", start: 3, duration: 1)
    ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    data_rows = doc.xpath("//w:tr", NS)[2..]

    assert_equal "1.1", data_rows[1].xpath("w:tc[1]//w:t", NS).text
    assert_equal "1.2", data_rows[2].xpath("w:tc[1]//w:t", NS).text
    assert_equal "2.1", data_rows[4].xpath("w:tc[1]//w:t", NS).text
  end

  test "shades only the period cells within [start_period, start_period+duration) as the activity bar" do
    items = [ item(phase: "F", activity: "A", start: 2, duration: 2) ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    activity_row = doc.xpath("//w:tr", NS)[2..].last
    period_fills = activity_row.xpath("w:tc", NS)[2..].map { |tc| tc.at_xpath(".//w:shd", NS)&.[]("w:fill") }

    assert_equal [ nil, "2E75B6", "2E75B6" ], period_fills
  end

  test "a milestone item is highlighted in orange instead of blue" do
    items = [ item(phase: "F", activity: "Marco", start: 1, duration: 1, milestone: true) ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    activity_row = doc.xpath("//w:tr", NS)[2..].last
    period_fill = activity_row.xpath("w:tc", NS)[2].at_xpath(".//w:shd", NS)["w:fill"]

    assert_equal "C65911", period_fill
  end

  test "alternates the zebra background between consecutive activity rows, never on phase rows" do
    items = [
      item(phase: "F", activity: "A", start: 1, duration: 1),
      item(phase: "F", activity: "B", start: 1, duration: 1),
      item(phase: "F", activity: "C", start: 1, duration: 1)
    ]

    doc = build_doc(items, start_date: Date.new(2026, 1, 1), unit: :week)
    data_rows = doc.xpath("//w:tr", NS)[2..]
    # linhas: [fase, A, B, C] — a célula de nome não tem barra, então reflete o zebra puro
    name_fills = data_rows[1..].map { |row| row.xpath("w:tc[2]", NS).first.at_xpath(".//w:shd", NS)&.[]("w:fill") }

    assert_equal [ nil, "F2F5F9", nil ], name_fills
  end

  test "escapes XML special characters in phase and activity names" do
    items = [ item(phase: "Fase A & B", activity: "Reunião <kick-off>", start: 1, duration: 1) ]

    xml = ScheduleTableBuilder.new(items, start_date: Date.new(2026, 1, 1), unit: :week).build_xml

    assert_includes xml, "Fase A &amp; B"
    assert_includes xml, "Reuni"
    assert_not_includes xml, "<kick-off>"
  end

  private
    def item(phase:, activity:, start:, duration:, milestone: false)
      ScheduleItem.new(schedule_type: "servico", phase_name: phase, activity_name: activity,
        start_period: start, duration_periods: duration, milestone: milestone, position: 0)
    end

    def build_doc(items, start_date:, unit:)
      xml = ScheduleTableBuilder.new(items, start_date: start_date, unit: unit).build_xml
      Nokogiri::XML(xml)
    end
end
