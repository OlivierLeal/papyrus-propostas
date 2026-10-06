module Spreadsheets
  # Executa o plano de preenchimento que a IA montou pra uma planilha do cliente (FillClientSpreadsheetJob).
  # A IA só aponta: "esta célula = fato X", "este preço unitário = estas peças de custo, nesta fração",
  # "esta tabela ganha uma linha por profissional". Todo número sai do FactCatalog ou de conta em Ruby
  # aqui — nunca da IA (CLAUDE.md seção 1). Tudo o que o plano pede e não fecha vira aviso ou pendência
  # no relatório, em vez de ser escrito errado em silêncio.
  #
  # Formato do plano:
  #   { "abas_mostrar": ["Remuneração"],
  #     "celulas": [{ "aba", "celula", "fato" | "texto" | "numero" }],
  #     "precos_unitarios": [{ "aba", "celula", "descricao", "quantidade" | "quantidade_celula",
  #                            "itens": [{ "item", "peso" }],   (itens da precificação — preferido)
  #                            "composicao": [{ "peca", "fracao" }] }],
  #     "tabelas": [{ "aba", "linha_modelo", "linhas": [{ "<coluna>" => { "fato" | "texto" | "numero" } }] }],
  #     "tipo_planilha": "preco" | "formulario",   (só planilha de preço tem o custo inteiro conferido)
  #     "faltando": ["..."],   (dado que a planilha pede e ninguém informou — só aviso no card)
  #     "duvidas": ["..."] }   (viram pendência que trava a geração — ProjectIssue source "planilha")
  class PlanExecutor
    Result = Data.define(:bytes, :entries, :warnings, :issues, :doubts, :totals, :used_keys, :missing_keys)

    # Texto livre que a IA pode escrever sem vir do catálogo: rótulo curto (Sim/Não/Horista…).
    MAX_FREE_TEXT = 120
    # Contagem pequena que a IA pode informar direto (nº de profissionais, meses…) — nunca dinheiro.
    MAX_FREE_NUMBER = 10_000
    FRACTION_TOLERANCE = 0.001

    def initialize(workbook, catalog, plan)
      @workbook = workbook
      @catalog = catalog
      @plan = plan.is_a?(Hash) ? plan : {}
      @entries = []
      @warnings = []
      @issues = []
      @usage = Hash.new(0.to_d)
      @used_keys = []
      @missing = {}
    end

    def call
      Array(@plan["abas_mostrar"]).each { |name| guard { @workbook.unhide(name) } }
      Array(@plan["celulas"]).each { |spec| write_cell(spec) }
      Array(@plan["tabelas"]).each { |spec| write_table(spec) }
      totals = write_unit_prices(Array(@plan["precos_unitarios"]))
      unit_price_mode = Array(@plan["precos_unitarios"]).any?
      price_sheet = unit_price_mode || @plan["tipo_planilha"].to_s == "preco"
      # Formulário que não é de preço (equipe, dados da empresa, checklist) não precisa cobrir o custo.
      check_coverage!(unit_price_mode: unit_price_mode) if price_sheet
      if !unit_price_mode && @used_keys.any? { |key| key.match?(/\AE\d/) }
        @warnings << "Custos externos entraram como custo na planilha e recebem o BDI dela — na proposta eles são repasse, sem BDI. Confira o total."
      end
      report_missing!
      doubts = Array(@plan["duvidas"]).map { |d| d.is_a?(Hash) ? d["pergunta"] : d }.map(&:to_s).compact_blank

      used = (@used_keys + @usage.keys + (price_sheet ? [ "proposta.total" ] : [])).uniq
      Result.new(@workbook.to_bytes, @entries, @warnings.uniq, @issues.uniq, doubts.uniq, totals, used, @missing.keys)
    end

    private

    def guard
      yield
    rescue Workbook::Error => e
      @warnings << e.message
      nil
    end

    def write_cell(spec)
      sheet, ref = spec.values_at("aba", "celula")
      value, origin = resolve(spec)
      return if value.nil?

      guard do
        current = @workbook.value(sheet, ref)
        value = "#{current.to_s.rstrip} #{value}" if value.is_a?(String) && current.is_a?(String) && current.rstrip.end_with?(":")
        @workbook.write(sheet, ref, value)
        @entries << { aba: sheet, celula: ref, valor: display(value), origem: origin }
      end
    end

    def write_table(spec)
      sheet = spec["aba"]
      template = spec["linha_modelo"].to_i
      rows = Array(spec["linhas"]).map do |row|
        row.to_h.filter_map do |column, cell_spec|
          next unless column.to_s.match?(/\A[A-Z]{1,3}\z/)

          value, origin = resolve(cell_spec.is_a?(Hash) ? cell_spec : { "texto" => cell_spec })
          [ column.to_s, value, origin ] unless value.nil?
        end
      end
      return @warnings << "#{sheet}: tabela sem linha-modelo válida" unless template.positive?

      guard do
        @workbook.fill_table(sheet, template, rows.map { |cells| cells.to_h { |column, value, _| [ column, value ] } })
        rows.each_with_index do |cells, index|
          cells.each do |column, value, origin|
            @entries << { aba: sheet, celula: "#{column}#{template + index}", valor: display(value), origem: origin }
          end
        end
      end
    end

    # Uma linha por dado que falta. Os percentuais de BDI viram uma só (são um bloco, no mesmo lugar),
    # e o "faltando" da IA não repete o que o sistema já apontou pelo catálogo (achado ao vivo:
    # 21 linhas no card da DFP, metade o mesmo dado duas vezes).
    def report_missing!
      bdi, others = @missing.partition { |key, _| key.start_with?("bdi.") }
      others.each { |key, label| @issues << "Falta informar: #{label} (#{key})." }
      if bdi.any?
        @issues << "Falta informar: percentuais de BDI da Papyrus (#{bdi.map(&:first).join(', ')}) — " \
          "sem eles a planilha não fecha o preço (config/papyrus_company.yml)."
      end
      known = @missing.flat_map { |key, label| [ key, label.downcase ] }
      Array(@plan["faltando"]).map(&:to_s).compact_blank.each do |text|
        next if text.match?(/n[ãa]o informado/i) || known.any? { |term| text.downcase.include?(term.downcase) }

        @issues << "Falta informar: #{text}"
      end
    end

    # [valor, origem] ou nil (com aviso/pendência registrado).
    def resolve(spec)
      spec = spec.to_h
      if (key = spec["fato"].presence)
        fact = @catalog[key]
        return (@warnings << "fato inexistente citado pela IA: #{key}"; nil) unless fact
        return (@missing[key] = fact.label; nil) if fact.missing?

        @used_keys << key
        [ fact.kind == :text ? fact.value.to_s : fact.value.to_d, "#{fact.label} (#{key})" ]
      elsif spec.key?("numero")
        number = spec["numero"].to_s.tr(",", ".").to_d
        return (@warnings << "número fora do permitido pra IA informar direto: #{spec['numero']}"; nil) unless number.abs <= MAX_FREE_NUMBER && number == number.round(2)

        [ number, "número informado pela IA (contagem)" ]
      elsif (text = spec["texto"].to_s.strip).present?
        return (@warnings << "texto numérico recusado (número tem que vir do sistema): #{text}"; nil) if text.match?(/\A[\sR$\d.,%-]+\z/)

        [ text.truncate(MAX_FREE_TEXT), "texto da IA" ]
      end
    end

    # Preço unitário = Σ(peça × fração × multiplicador) ÷ quantidade do cliente. A soma de
    # quantidade × unitário tem que dar o total da proposta; o item de menor quantidade absorve o
    # arredondamento (o resíduo que sobrar, de centavos, vai pro relatório).
    def write_unit_prices(specs)
      specs = expand_item_compositions(specs)
      scale = fraction_scale(specs)
      rows = specs.filter_map do |spec|
        quantity = quantity_for(spec)
        next (@warnings << "#{spec['aba']}!#{spec['celula']}: quantidade não encontrada"; nil) unless quantity&.positive?

        amount = Array(spec["composicao"]).sum(0.to_d) do |part|
          key = part["peca"].to_s
          fact = @catalog[key]
          next (@warnings << "peça inexistente citada pela IA: #{key}"; 0.to_d) unless fact&.piece

          fraction = part["fracao"].to_d * scale.fetch(key, 1)
          @usage[key] += fraction
          fact.value * fraction * @catalog.piece_multiplier(key)
        end
        { spec: spec, quantity: quantity, amount: amount, unit: (amount / quantity).round(2) }
      end
      return nil if rows.empty?

      target = @catalog["proposta.total"].value.round(2)
      # Só absorve ARREDONDAMENTO (meio centavo por unidade): se faltou peça no rateio, a diferença
      # é grande e fica à mostra (check_coverage! já avisa), nunca escondida num item.
      rounding_room = rows.sum(0.to_d) { |row| row[:quantity] } * 0.005.to_d + 0.01.to_d
      if (rows.sum(0.to_d) { |row| row[:amount] } - target).abs <= rounding_room
        adjust = rows.min_by { |row| row[:quantity] }
        others = rows.reject { |row| row.equal?(adjust) }.sum(0.to_d) { |row| row[:unit] * row[:quantity] }
        adjust[:unit] = ((target - others) / adjust[:quantity]).round(2)
      end

      rows.each do |row|
        spec = row[:spec]
        guard do
          @workbook.write(spec["aba"], spec["celula"], row[:unit])
          parts = spec["rateio"] || composition_text(spec, scale)
          @entries << { aba: spec["aba"], celula: spec["celula"], valor: display(row[:unit]),
                        origem: "#{spec['descricao'].presence || 'preço unitário'}: (#{parts.truncate(260)}) × BDI e impostos ÷ #{number(row[:quantity])}" }
        end
      end

      sheet_total = rows.sum(0.to_d) { |row| row[:unit] * row[:quantity] }
      residual = (sheet_total - target).round(2)
      @warnings << "A planilha soma R$ #{display(sheet_total)}, #{residual.positive? ? 'acima' : 'abaixo'} do total da proposta em R$ #{display(residual.abs)} (arredondamento do preço unitário)." unless residual.zero?
      { planilha: sheet_total.to_f, proposta: target.to_f }
    end

    def composition_text(spec, scale)
      Array(spec["composicao"]).filter_map do |part|
        fraction = part["fracao"].to_d * scale.fetch(part["peca"].to_s, 1)
        next if fraction.zero?

        "#{part['peca']}#{" × #{number(fraction)}" unless fraction == 1}"
      end.join(" + ")
    end

    # A IA erra a conta das frações (0,6 + 0,3 numa peça). Mantém a PROPORÇÃO que ela quis entre os
    # itens e fecha em 100% — avisando. Peça fora do rateio (soma 0) não tem proporção: vira pendência.
    def fraction_scale(specs)
      sums = Hash.new(0.to_d)
      specs.each { |spec| Array(spec["composicao"]).each { |part| sums[part["peca"].to_s] += part["fracao"].to_d } }
      sums.each_with_object({}) do |(key, sum), scale|
        next if sum <= 0 || (sum - 1).abs <= FRACTION_TOLERANCE

        scale[key] = 1 / sum
        @warnings << "Rateio de #{@catalog[key]&.label || key} (#{key}) somava #{number(sum * 100)}%; ajustado pra 100% mantendo a proporção entre os itens."
      end
    end

    def quantity_for(spec)
      return spec["quantidade"].to_s.tr(",", ".").to_d if spec["quantidade"].present?

      ref = spec["quantidade_celula"].presence || quantity_cell_in_row(spec["aba"], spec["celula"].to_s)
      value = ref && guard { @workbook.value(spec["aba"], ref) }
      value.is_a?(Numeric) ? value.to_d : nil
    end

    # A IA às vezes não diz onde está a quantidade (proposta 69: 53 linhas, nenhuma com quantidade —
    # planilha saiu vazia). A quantidade da linha é a coluna cujo cabeçalho, acima, diz "QUANTIDADE".
    def quantity_cell_in_row(sheet, ref)
      row = ref[/\d+/].to_i
      return if sheet.blank? || row.zero?

      @sheet_cells ||= {}
      cells = (@sheet_cells[sheet] ||= guard { @workbook.cells(sheet) } || [])
      header = cells.select do |cell|
        cell.ref[/\d+/].to_i < row && cell.value.is_a?(String) && I18n.transliterate(cell.value).match?(/\bQUANT/i)
      end.max_by { |cell| cell.ref[/\d+/].to_i }
      header && "#{header.ref[/[A-Z]+/]}#{row}"
    end

    # Rateio por ITEM da precificação (preferido, 2026-10): a IA só diz a que item(ns) cada linha do
    # cliente corresponde (e um peso, se não forem iguais); o Ruby distribui TODAS as peças do item
    # entre as linhas que o citam. Peça de item que nenhuma linha cita (gestão, custo externo) é
    # comum: vai pra todas as linhas na proporção do custo próprio delas. Assim toda peça entra uma
    # vez por construção — na proposta 69 a IA errou as frações de 30 peças e citou "C5" (o campo
    # inteiro, que não é peça). "composicao" explícita continua valendo e não é rateada de novo.
    def expand_item_compositions(specs)
      specs = specs.map { |spec| spec.merge("composicao" => expand_groups(Array(spec["composicao"]))) }
      rows_of_item = Hash.new { |hash, key| hash[key] = [] }
      specs.each_with_index { |spec, index| item_refs(spec).each { |id, weight| rows_of_item[id] << [ index, weight ] } }
      return specs if rows_of_item.empty?

      direct = specs.flat_map { |spec| spec["composicao"].map { |part| part["peca"].to_s } }.to_set
      extra = Array.new(specs.size) { [] }
      common = []
      @catalog.pieces.each do |piece|
        next if direct.include?(piece.key)

        rows = rows_of_item[@catalog.item_of(piece.key)]
        next common << piece if rows.empty?

        total = rows.sum(0.to_d) { |_, weight| weight }
        rows.each { |index, weight| extra[index] << { "peca" => piece.key, "fracao" => weight / total } }
      end
      notes = Array.new(specs.size) { [] }
      rows_of_item.each do |id, rows|
        name = @catalog.pricing.pricing_items.find { |item| item.id == id }&.name || "item #{id}"
        total = rows.sum(0.to_d) { |_, weight| weight }
        rows.each { |index, weight| notes[index] << "#{name}#{" × #{number(weight / total * 100)}%" unless weight == total}" }
      end

      if common.any?
        own = specs.each_with_index.map do |spec, index|
          (spec["composicao"] + extra[index]).sum(0.to_d) { |part| piece_amount(part) }
        end
        total_own = own.sum
        specs.each_index do |index|
          share = total_own.positive? ? own[index] / total_own : 1.to_d / specs.size
          next if share.zero?

          common.each { |piece| extra[index] << { "peca" => piece.key, "fracao" => share } }
          notes[index] << "#{number(share * 100)}% dos custos comuns"
        end
      end
      specs.each_with_index.map do |spec, index|
        spec.merge("composicao" => spec["composicao"] + extra[index], "rateio" => notes[index].join(" + ").presence)
      end
    end

    def item_refs(spec)
      refs = Array(spec["itens"]).map { |ref| ref.is_a?(Hash) ? [ ref["item"], ref["peso"] ] : [ ref, nil ] }
      refs << [ spec["item"], nil ] if spec["item"].present?
      refs.filter_map do |id, weight|
        weight = weight.present? ? weight.to_s.tr(",", ".").to_d : 1.to_d
        [ id.to_s[/\d+/].to_i, weight ] if id.to_s[/\d+/] && weight.positive?
      end
    end

    # "C5" (o campo inteiro) vira as peças dele (C5.veiculo, C5.combustivel…), com a mesma fração.
    def expand_groups(parts)
      parts.flat_map do |part|
        key = part["peca"].to_s
        next [ part ] if @catalog[key]&.piece

        group = @catalog.pieces.select { |piece| piece.key.start_with?("#{key}.") }
        group.any? ? group.map { |piece| part.merge("peca" => piece.key) } : [ part ]
      end
    end

    def piece_amount(part)
      fact = @catalog[part["peca"].to_s]
      return 0.to_d unless fact&.piece

      fact.value * part["fracao"].to_d * @catalog.piece_multiplier(fact.key)
    end

    # Toda peça de custo tem que entrar uma vez (rateio: frações somando 1).
    def check_coverage!(unit_price_mode:)
      @catalog.pieces.each do |piece|
        used = if unit_price_mode
          @usage[piece.key]
        else
          @used_keys.any? { |key| key == piece.key || key.start_with?("#{piece.key}.") } ? 1 : 0
        end
        next if (used - 1).abs <= FRACTION_TOLERANCE

        @issues << if used.zero?
          "Custo que não entrou na planilha: #{piece.label} (#{piece.key}, R$ #{display(piece.value)})."
        else
          "Custo rateado em #{number(used * 100)}% em vez de 100%: #{piece.label} (#{piece.key})."
        end
      end
    end

    def display(value)
      return value.to_s unless value.is_a?(Numeric)

      precision = value.nonzero? && value.abs < 1 ? 4 : 2 # fração (tributo 0,0065) não pode virar 0,01
      ActiveSupport::NumberHelper.number_to_rounded(value.to_d, precision: precision, delimiter: ".", separator: ",", strip_insignificant_zeros: precision == 4)
    end

    def number(value) = value.to_d.round(3).to_s("F").sub(/\.0\z/, "")
  end
end
