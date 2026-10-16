module Spreadsheets
  # Planilha orçamentária da própria Papyrus, montada do zero a partir da precificação (conversa 79,
  # 2026-10-16: "gere uma planilha do zero, não precisa obedecer um modelo"; a que saiu do
  # preenchimento veio em branco, e a consultora queria "os preços das horas, o BDI, os impostos…
  # se eu alterar lá muda o preço?"). Tudo Ruby, sem IA: cada linha é quantidade × valor unitário
  # em fórmula, BDI e impostos ficam em células editáveis NO TOPO da mesma aba e o total recalcula
  # quando mudam. Os valores de cada fórmula também vão gravados (quem abre num visualizador sem
  # recálculo vê os números), e o Excel/LibreOffice recalcula ao abrir (fullCalcOnLoad).
  #
  # Mesma conta do motor (ProjectPricing#price_composition): custo direto (equipe + logística dos
  # campos + custos dos itens) × BDI × impostos, mais custos externos e terceirizados sem margem.
  # O motor arredonda linha a linha; a planilha aplica as margens sobre o subtotal — pode dar
  # centavos de diferença, que #call devolve em `difference`.
  class BudgetBuilder
    Result = Data.define(:bytes, :total, :difference)

    MAIN_SHEET = "Orçamento".freeze

    # Estilos (índice em cellXfs de #styles_xml).
    TEXT, BOLD, MONEY, BOLD_MONEY, HEADER, QTY, INPUT, TITLE, GROUP, PERCENT = (0..9).to_a

    def initialize(proposal)
      @proposal = proposal
      @pricing = proposal.project_pricing
      @rows = []
    end

    def call
      build_rows
      total = @values.fetch(@total_ref)
      Result.new(bytes: package, total: total, difference: (@pricing.total_value.to_d - total).round(2))
    end

    private
      def build_rows
        @values = {}
        add [ [ "PLANILHA ORÇAMENTÁRIA — #{@proposal.docx_numero_proposta}", TITLE ] ]
        add [ [ "Cliente: #{@proposal.conversation.client_name}", TEXT ] ]
        add [ [ "Gerada em #{Date.current.strftime('%d/%m/%Y')} a partir da Tela de Precificação. Altere as células amarelas e o preço recalcula.", TEXT ] ]
        add []
        add [ [ "PARÂMETROS", GROUP ] ]
        bdi_cell = param_row("BDI (multiplicador — 1,30 = 30%)", @pricing.bdi)
        tax_cell = param_row("Impostos e despesas administrativas (multiplicador — 1,25 = 25%)", @pricing.tax_multiplier)
        add []
        add [ "Nº", "Descrição", "Qtd", "Unid", "Valor unit. (R$)", "Total (R$)" ].map { |label| [ label, HEADER ] }

        @number = 0
        cost_refs = []
        items = @pricing.pricing_items.includes(:field_campaigns, proposal_professionals: :professional).to_a
        items.each do |item|
          add [ nil, [ item.name.upcase, GROUP ] ] if items.size > 1
          cost_refs.concat(item_rows(item))
        end

        add []
        direct_ref = sum_row("SUBTOTAL — CUSTO DIRETO", cost_refs)
        bdi_ref = formula_row("BDI", "ROUND(#{direct_ref}*(#{bdi_cell}-1),2)", (@values[direct_ref] * (@pricing.bdi - 1)).round(2))
        taxes_value = ((@values[direct_ref] + @values[bdi_ref]) * (@pricing.tax_multiplier - 1)).round(2)
        taxes_ref = formula_row("Impostos e despesas administrativas", "ROUND((#{direct_ref}+#{bdi_ref})*(#{tax_cell}-1),2)", taxes_value)
        price_refs = [ direct_ref, bdi_ref, taxes_ref ]

        if @pricing.external_costs.any?
          add []
          add [ nil, [ "CUSTOS EXTERNOS E SERVIÇOS DE TERCEIROS (repasse, sem BDI)", GROUP ] ]
          @pricing.external_costs.each do |cost|
            label = cost["kind"] == "terceirizado" ? "Serviço terceirizado: #{cost['description']}" : cost["description"].to_s
            price_refs << line_row(label, 1, "vb", cost["value"].to_d)
          end
        end

        add []
        @total_ref = sum_row("PREÇO TOTAL", price_refs)
      end

      def item_rows(item)
        refs = []
        factor = item.days_factor
        item.proposal_professionals.sort_by { |line| [ line.professional.always_included ? 0 : 1, line.id ] }.each do |line|
          who = [ line.professional.name, line.deliverable_name.presence ].compact.join(" – ")
          refs << line_row("Produto: #{who}", 1, "vb", line.fixed_amount) if line.fixed_amount.positive?
          refs << line_row("Horas-homem: #{who}", line.man_hours, "HH", line.hour_rate) if line.man_hours.positive?
          days = line.field_days + line.commute_extra_days(factor)
          refs << line_row("Diárias de campo: #{who}", days, "diária", line.day_rate) if days.positive?
        end
        item.field_campaigns.each { |campaign| refs.concat(campaign_rows(campaign)) }
        item.costs.each do |cost|
          next unless (cost["quantity"].to_d * cost["unit_value"].to_d).positive?

          refs << line_row(cost["description"].to_s, cost["quantity"].to_d, "un", cost["unit_value"].to_d)
        end
        refs
      end

      # Mesma decomposição de FieldCampaign#breakdown, mas com quantidade e valor unitário à mostra.
      def campaign_rows(campaign)
        pricing = @pricing
        rental = campaign.vehicle_type == "4x4" ? pricing.rental_4x4_per_day : pricing.rental_per_day
        consumption = pricing.vehicle_consumption_km_per_liter.positive? ? pricing.vehicle_consumption_km_per_liter : 1
        prefix = "Logística – #{campaign.description}"
        rows = [
          [ "#{prefix}: veículo (#{campaign.vehicle_type})", campaign.vehicles * campaign.trip_days, "diária", rental ],
          [ "#{prefix}: combustível", (campaign.km(pricing) * campaign.vehicles / consumption).to_d.round(2), "litro", pricing.fuel_price_per_liter ],
          [ "#{prefix}: alimentação", campaign.people * campaign.trip_days, "pessoa/dia", pricing.meal_per_person_per_day ],
          [ "#{prefix}: hospedagem", campaign.people * campaign.nights, "pernoite", campaign.lodging_rate(pricing) ],
          [ "#{prefix}: pedágios", campaign.tolls, "un", pricing.toll_price ],
          [ "#{prefix}: lavagens", campaign.washes, "un", pricing.wash_price ],
          [ "#{prefix}: Uber/táxi", campaign.uber_trips, "viagem", pricing.uber_price ],
          [ "#{prefix}: mateiro", campaign.mateiro_days, "diária", pricing.mateiro_per_day ],
          [ "#{prefix}: EPI/ASO", campaign.epi_count, "un", pricing.epi_price ]
        ]
        rows.filter_map do |label, quantity, unit, rate|
          next unless (quantity.to_d * rate.to_d).positive?

          line_row(label, quantity.to_d, unit, rate.to_d)
        end
      end

      def param_row(label, value)
        add [ nil, [ label, TEXT ], nil, nil, nil, [ value.to_d, INPUT ] ]
        "$F$#{@rows.size}"
      end

      def line_row(label, quantity, unit, rate)
        row = @rows.size + 1
        value = (quantity.to_d * rate.to_d).round(2)
        @values["F#{row}"] = value
        add [ [ (@number += 1).to_s, TEXT ], [ label, TEXT ], [ quantity.to_d, QTY ], [ unit, TEXT ], [ rate.to_d, MONEY ],
              [ { formula: "ROUND(C#{row}*E#{row},2)", value: value }, MONEY ] ]
        "F#{row}"
      end

      def formula_row(label, formula, value)
        row = @rows.size + 1
        @values["F#{row}"] = value
        add [ nil, [ label, BOLD ], nil, nil, nil, [ { formula: formula, value: value }, BOLD_MONEY ] ]
        "F#{row}"
      end

      def sum_row(label, refs)
        formula_row(label, refs.empty? ? "0" : refs.join("+"), refs.sum { |ref| @values.fetch(ref) })
      end

      def add(cells)
        @rows << cells
      end

      def package
        buffer = Zip::OutputStream.write_buffer do |zip|
          {
            "[Content_Types].xml" => content_types_xml, "_rels/.rels" => root_rels_xml,
            "xl/workbook.xml" => workbook_xml, "xl/_rels/workbook.xml.rels" => workbook_rels_xml,
            "xl/styles.xml" => styles_xml, "xl/worksheets/sheet1.xml" => main_sheet_xml,
            "xl/worksheets/sheet2.xml" => payment_sheet_xml
          }.each do |name, xml|
            zip.put_next_entry(name)
            zip.write(xml)
          end
        end
        buffer.string
      end

      def main_sheet_xml
        sheet_xml(@rows, widths: [ 6, 70, 10, 12, 16, 18 ])
      end

      # Desembolso: % de cada parcela × o preço total da aba Orçamento (muda junto com o BDI).
      def payment_sheet_xml
        rows = [ [ [ "CRONOGRAMA DE DESEMBOLSO", TITLE ] ], [], [ "Nº", "Marco", "%", "Valor (R$)" ].map { |label| [ label, HEADER ] } ]
        total = @values.fetch(@total_ref)
        @pricing.payment_schedule.each_with_index do |item, index|
          row = rows.size + 1
          percent = item["percentage"].to_d / 100
          rows << [ [ (index + 1).to_s, TEXT ], [ item["label"].to_s, TEXT ], [ percent, PERCENT ],
                    [ { formula: "ROUND('#{MAIN_SHEET}'!#{@total_ref.sub('F', '$F$')}*C#{row},2)", value: (total * percent).round(2) }, MONEY ] ]
        end
        sheet_xml(rows, widths: [ 6, 50, 10, 18 ])
      end

      def sheet_xml(rows, widths:)
        cols = widths.each_with_index.map { |width, index| %(<col min="#{index + 1}" max="#{index + 1}" width="#{width}" customWidth="1"/>) }.join
        body = rows.each_with_index.map do |cells, index|
          row = index + 1
          xml = cells.each_with_index.filter_map do |cell, column|
            next if cell.nil?

            cell_xml("#{(65 + column).chr}#{row}", *cell)
          end.join
          %(<row r="#{row}">#{xml}</row>)
        end.join
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <cols>#{cols}</cols><sheetData>#{body}</sheetData>
          <pageSetup orientation="landscape" fitToWidth="1" fitToHeight="0"/>
          </worksheet>
        XML
      end

      def cell_xml(ref, content, style)
        case content
        when Hash
          %(<c r="#{ref}" s="#{style}"><f>#{CGI.escapeHTML(content[:formula])}</f><v>#{content[:value].to_d.to_s('F')}</v></c>)
        when Numeric
          %(<c r="#{ref}" s="#{style}"><v>#{content.to_d.to_s('F')}</v></c>)
        else
          %(<c r="#{ref}" s="#{style}" t="inlineStr"><is><t xml:space="preserve">#{CGI.escapeHTML(content.to_s)}</t></is></c>)
        end
      end

      def workbook_xml
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="#{MAIN_SHEET}" sheetId="1" r:id="rId1"/><sheet name="Desembolso" sheetId="2" r:id="rId2"/></sheets>
          <calcPr calcId="191029" fullCalcOnLoad="1"/>
          </workbook>
        XML
      end

      def workbook_rels_xml
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
          </Relationships>
        XML
      end

      def root_rels_xml
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
          </Relationships>
        XML
      end

      def content_types_xml
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
          </Types>
        XML
      end

      # Ordem de cellXfs = constantes TEXT..PERCENT. Cores do Manual de Identidade Visual (azul
      # institucional no cabeçalho, amarelo claro nas células editáveis).
      def styles_xml
        <<~XML.delete("\n")
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts>
          <fonts count="4">
          <font><sz val="10"/><name val="Arial"/></font>
          <font><b/><sz val="10"/><name val="Arial"/></font>
          <font><b/><sz val="10"/><color rgb="FFFFFFFF"/><name val="Arial"/></font>
          <font><b/><sz val="13"/><color rgb="FF1F3864"/><name val="Arial"/></font>
          </fonts>
          <fills count="5">
          <fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FF1F3864"/></patternFill></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/></patternFill></fill>
          <fill><patternFill patternType="solid"><fgColor rgb="FFD9E1F2"/></patternFill></fill>
          </fills>
          <borders count="2"><border/><border><left style="thin"/><right style="thin"/><top style="thin"/><bottom style="thin"/></border></borders>
          <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
          <cellXfs count="10">
          <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
          <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
          <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          <xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
          <xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
          <xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          <xf numFmtId="2" fontId="1" fillId="3" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1" applyBorder="1"/>
          <xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>
          <xf numFmtId="0" fontId="1" fillId="4" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
          <xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
          </cellXfs>
          </styleSheet>
        XML
      end
  end
end
