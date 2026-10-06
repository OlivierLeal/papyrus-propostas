module Spreadsheets
  # Tudo o que o sistema SABE sobre a proposta, com chave estável, pra IA citar ao montar o plano de
  # preenchimento de uma planilha do cliente (ver PlanExecutor). A IA nunca escreve número: ela diz
  # "esta célula = L128.valor_hh"; o valor sai daqui, calculado em Ruby (CLAUDE.md seção 1).
  #
  # "Peças de custo" (`pieces`) são os pedaços do CUSTO DIRETO da proposta — linha de equipe, cada
  # categoria de logística de cada campo, cada custo de item — mais os custos externos (repasse). O
  # rateio de uma PPU distribui as peças entre os itens do cliente; a checagem de cobertura garante
  # que nenhuma ficou de fora nem entrou duas vezes.
  class FactCatalog
    Fact = Data.define(:key, :label, :value, :kind, :piece) do
      def missing? = value.nil?
    end

    CAMPAIGN_CATEGORIES = {
      "veiculo" => "aluguel de veículos", "combustivel" => "combustível", "alimentacao" => "alimentação",
      "hospedagem" => "hospedagem", "pedagio" => "pedágios", "lavagem" => "lavagens",
      "uber" => "deslocamentos locais (Uber)", "mateiro" => "mateiro", "epi" => "EPI/ASO"
    }.freeze

    attr_reader :proposal, :pricing

    def initialize(proposal)
      @proposal = proposal
      @pricing = proposal.project_pricing
      @facts = {}
      @piece_items = {}
      build!
    end

    def [](key) = @facts[key.to_s]
    def facts = @facts.values
    def pieces = facts.select(&:piece)

    # Multiplicador de uma peça no PREÇO: BDI × impostos, menos os externos (repasse).
    # Item da precificação de onde a peça vem (nil = externo, comum a todos).
    def item_of(key) = @piece_items[key.to_s]

    def piece_multiplier(key) = key.to_s.start_with?("E") ? 1 : pricing.multiplier

    # Impressão digital dos fatos que um preenchimento usou: se mudar, a planilha preenchida está
    # desatualizada (SpreadsheetFill#stale?). Fato que sumiu (linha removida) também muda.
    def digest(keys)
      Digest::SHA256.hexdigest((keys.map(&:to_s).uniq - [ "hoje.data" ]).sort.map { |key| "#{key}=#{self[key]&.value}" }.join("\n"))
    end

    # Texto pro prompt: uma linha por fato, com o valor (a IA precisa ver pra entender o que é, mas é
    # instruída a nunca copiar número — só a chave).
    def to_prompt_text
      [ items_prompt_text, facts_prompt_text ].compact_blank.join("\n\n")
    end

    # Itens da precificação com o custo (com BDI e impostos) e as peças de cada um — é por eles que a
    # IA mapeia as linhas de uma lista de preços do cliente ("itens" em precos_unitarios).
    def items_prompt_text
      by_item = pieces.group_by { |piece| item_of(piece.key) }
      lines = pricing.pricing_items.order(:position).map do |item|
        own = Array(by_item[item.id])
        price = own.sum(0.to_d) { |piece| piece.value * piece_multiplier(piece.key) }
        "item #{item.id} = #{display(Fact.new('', '', price.round(2), :money, false))} — #{item.name} " \
          "(#{own.size} peças: #{own.map(&:key).first(12).join(', ')}#{', …' if own.size > 12})"
      end
      common = Array(by_item[nil])
      lines << "sem item (custos externos, rateados entre todas as linhas): #{common.map(&:key).join(', ')}" if common.any?
      "ITENS DA PRECIFICAÇÃO (preço com BDI e impostos)\n#{lines.join("\n")}"
    end

    def facts_prompt_text
      facts.group_by { |fact| fact.key.split(".").first.sub(/\d.*/, "") }.map do |_, group|
        group.map do |fact|
          shown = fact.missing? ? "NÃO INFORMADO" : display(fact)
          "#{fact.key} = #{shown} — #{fact.label}#{" [peça de custo]" if fact.piece}"
        end.join("\n")
      end.join("\n\n")
    end

    private

    def build!
      company!
      proposal_facts!
      team!
      campaigns!
      item_costs!
      external!
      taxes_and_bdi!
    end

    def add(key, label, value, kind, piece: false)
      @facts[key] = Fact.new(key, label, value, kind, piece)
    end

    def company!
      add("papyrus.razao_social", "Razão social da Papyrus", PapyrusCompany["razao_social"], :text)
      add("papyrus.cnpj", "CNPJ da Papyrus", PapyrusCompany["cnpj"], :text)
      add("papyrus.municipio_faturamento", "Município de faturamento", PapyrusCompany["municipio_faturamento"], :text)
      add("papyrus.regime_tributario", "Regime tributário", PapyrusCompany["regime_tributario"], :text)
      add("papyrus.sindicato", "Sindicato considerado na proposta", PapyrusCompany["sindicato"], :text)
      add("papyrus.data_base_reajuste", "Data-base do reajuste salarial", PapyrusCompany["data_base_reajuste"], :text)
      add("hoje.data", "Data de hoje (dd/mm/aaaa)", Date.current.strftime("%d/%m/%Y"), :text)
    end

    def proposal_facts!
      add("proposta.numero", "Número da proposta", proposal.docx_numero_proposta, :text)
      add("proposta.cliente", "Cliente", proposal.conversation.client_name, :text)
      add("proposta.total", "Preço total da proposta (com BDI e impostos)", pricing.total_value.to_d, :money)
      add("proposta.custo_direto", "Custo direto total (sem BDI/impostos)", pricing.price_composition[:direct], :money)
      add("proposta.bdi_multiplicador", "BDI (multiplicador, ex. 1,30)", pricing.bdi.to_d, :number)
      add("proposta.impostos_multiplicador", "Impostos e ADM (multiplicador, ex. 1,25)", pricing.tax_multiplier.to_d, :number)
    end

    def team!
      factors = pricing.days_factors
      pricing.proposal_professionals.includes(:professional).order(:id).each do |line|
        pro = line.professional
        k = "L#{line.id}"
        charges = pro.social_charges_percent&.to_d
        days = line.field_days + line.commute_extra_days(factors[line.pricing_item_id])
        cost = line.direct_cost(factors[line.pricing_item_id]).round(2)
        # Sem custo (Diretoria com custo no BDI, linha a 0h) não é peça: não há o que ratear.
        add("#{k}", "#{pro.name} – #{line.deliverable_name}#{' (custo incluso no BDI)' if pro.cost_in_bdi?}", cost, :money, piece: cost.positive?)
        @piece_items[k] = line.pricing_item_id
        add("#{k}.descricao", "Descrição (profissional – entregável)", "#{pro.name} – #{line.deliverable_name}", :text)
        add("#{k}.profissional", "Nome", pro.name, :text)
        add("#{k}.cargo", "Cargo", pro.role, :text)
        add("#{k}.entregavel", "Entregável/função nesta proposta", line.deliverable_name, :text)
        add("#{k}.hh", "Horas-homem", line.man_hours.to_d, :number)
        add("#{k}.valor_hh", "Valor da hora-homem (cheio, sem BDI)", pro.rate_man_hour.to_d, :money)
        add("#{k}.diarias", "Diárias de campo (com acréscimo de deslocamento)", days, :number)
        add("#{k}.valor_diaria", "Valor da diária (cheio, sem BDI)", pro.rate_daily.to_d, :money)
        add("#{k}.horas_diarias", "Diárias convertidas em horas (× 8)", days * 8, :number)
        add("#{k}.valor_hora_diaria", "Valor da diária por hora (÷ 8)", pro.rate_daily.to_d / 8, :money)
        add("#{k}.encargos_pct", "Encargos sociais (fração do salário)#{' — não informado, valor cheio' unless charges}", charges || 0, :percent)
        add("#{k}.salario_hh", "Salário por hora-homem, sem encargos", pro.rate_man_hour.to_d / (1 + (charges || 0)), :money)
        add("#{k}.salario_hora_diaria", "Salário por hora de diária, sem encargos", pro.rate_daily.to_d / 8 / (1 + (charges || 0)), :money)
      end
    end

    def campaigns!
      pricing.pricing_items.includes(:field_campaigns).each do |item|
        item.field_campaigns.each do |campaign|
          k = "C#{campaign.id}"
          add("#{k}.descricao", "Campo (#{item.name})", campaign.description, :text)
          add("#{k}.pessoas", "Pessoas em campo", campaign.people, :number)
          add("#{k}.dias", "Dias em campo (ajustados)", campaign.effective_days.to_d, :number)
          campaign_values(campaign).each do |category, value|
            next unless value.positive?

            add("#{k}.#{category}", "#{CAMPAIGN_CATEGORIES.fetch(category)} – #{campaign.description}", value.round(2), :money, piece: true)
            @piece_items["#{k}.#{category}"] = item.id
          end
        end
      end
    end

    # FieldCampaign#breakdown junta os extras; aqui eles saem separados (planilha de formação de
    # preço tem linha própria pra pedágio, EPI…). A soma é a mesma do breakdown.
    def campaign_values(campaign)
      b = campaign.breakdown(pricing)
      extras = {
        "pedagio" => campaign.tolls * pricing.toll_price, "lavagem" => campaign.washes * pricing.wash_price,
        "uber" => campaign.uber_trips * pricing.uber_price, "mateiro" => campaign.mateiro_days * pricing.mateiro_per_day,
        "epi" => campaign.epi_count * pricing.epi_price
      }.transform_values(&:to_d)
      { "veiculo" => b[:vehicle], "combustivel" => b[:fuel], "alimentacao" => b[:meals], "hospedagem" => b[:lodging] }
        .transform_values(&:to_d).merge(extras)
    end

    def item_costs!
      pricing.pricing_items.each do |item|
        item.costs.each_with_index do |cost, index|
          k = "K#{item.id}_#{index}"
          value = cost["quantity"].to_d * cost["unit_value"].to_d
          add(k, "#{cost['description']} (#{item.name})", value.round(2), :money, piece: value.positive?)
          @piece_items[k] = item.id
          add("#{k}.quantidade", "Quantidade", cost["quantity"].to_d, :number)
          add("#{k}.valor_unitario", "Valor unitário", cost["unit_value"].to_d, :money)
        end
      end
    end

    # Terceirizado nunca aparece como tal (regra da proposta): descrição genérica.
    def external!
      pricing.external_costs.each_with_index do |cost, index|
        label = cost["kind"] == "terceirizado" ? "Serviços especializados" : cost["description"].to_s
        add("E#{index}", "#{label} (custo externo, repasse sem BDI)", cost["value"].to_d, :money, piece: true)
        add("E#{index}.descricao", "Descrição do custo externo", label, :text)
      end
    end

    # Planilha de formação de preço (DFP): preço = custo × (1 + adm + riscos + seguros) × (1 + desp.
    # financeiras) × (1 + lucro) ÷ (1 − tributos). A administração central é o item de equilíbrio,
    # pra fechar com o BDI × impostos da proposta; as outras a Papyrus informa (config).
    def taxes_and_bdi!
      t = PapyrusCompany.data["tributos"] || {}
      add("tributo.iss", "ISS (fração)", t["iss"]&.to_d, :percent)
      add("tributo.pis", "PIS (fração)", t["pis"]&.to_d, :percent)
      add("tributo.cofins", "COFINS (fração)", t["cofins"]&.to_d, :percent)
      add("tributo.cprb", "CPRB (fração)", t["cprb"]&.to_d, :percent)
      outros = t["ir"] && t["csll"] ? t["ir"].to_d + t["csll"].to_d : nil
      add("tributo.outros", "Outros tributos sobre o faturamento: IR + CSLL (fração)", outros, :percent)

      c = PapyrusCompany.data["bdi_componentes"] || {}
      lucro, riscos, seguros, financeiras = c.values_at("lucro", "riscos", "seguros_garantias", "despesas_financeiras").map { |v| v&.to_d }
      add("bdi.lucro", "Margem de lucro (fração)", lucro, :percent)
      add("bdi.riscos", "Riscos (fração)", riscos, :percent)
      add("bdi.seguros_garantias", "Seguros e garantias (fração)", seguros, :percent)
      add("bdi.despesas_financeiras", "Despesas financeiras (fração)", financeiras, :percent)

      taxes = [ t["iss"], t["pis"], t["cofins"], t["cprb"] ].compact.sum(0.to_d) + (outros || 0)
      admin = if [ lucro, riscos, seguros, financeiras ].none?(&:nil?)
        (pricing.multiplier * (1 - taxes) / ((1 + financeiras) * (1 + lucro)) - 1 - riscos - seguros).round(6)
      end
      add("bdi.administracao_central", "Administração central (fração, calculada pra fechar com BDI × impostos)", admin, :percent)
    end

    def display(fact)
      case fact.kind
      when :money then "R$ #{ActiveSupport::NumberHelper.number_to_rounded(fact.value.to_d, precision: 2, delimiter: ".", separator: ",")}"
      when :percent then "#{(fact.value.to_d * 100).round(4).to_s('F').sub(/\.0\z/, '')}%"
      when :number then fact.value.to_d.round(4).to_s("F").sub(/\.0\z/, "")
      else fact.value.to_s.truncate(120)
      end
    end
  end
end
