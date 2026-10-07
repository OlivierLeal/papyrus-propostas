module ProposalsHelper
  def brl(value)
    number_to_currency(value, unit: "R$", separator: ",", delimiter: ".")
  end

  def initials(name)
    name.to_s.split.first(2).map { |part| part[0] }.join.upcase
  end

  # Campo numérico da Tela de Precificação com prefixo/sufixo dentro do input (daisyUI 5:
  # <label class="input"> envolvendo o <input>). `form_id` liga o campo a um <form> que está em
  # outro ponto da página (atributo HTML `form=`), pra não aninhar formulários.
  # Decimais usam step: "any" — com step fixo (1, 0.01) o navegador recusa o envio de qualquer
  # valor fora do passo ("Selecione um valor válido… 429 e 430"), inclusive os que o próprio
  # sistema sugere (distância da Mapbox com 1 casa decimal). Relato do consultor, 2026-09-28.
  def pricing_number_field(builder, attribute, prefix: nil, suffix: nil, disabled: false, **options)
    tag.label(class: "input input-sm w-full #{'input-disabled' if disabled}") do
      safe_join([
        (tag.span(prefix, class: "text-base-content/40 text-xs") if prefix),
        builder.number_field(attribute, disabled: disabled, autocomplete: "off", class: "grow text-right", **options),
        (tag.span(suffix, class: "text-base-content/40 text-xs whitespace-nowrap") if suffix)
      ].compact)
    end
  end

  # Botão de mudança de estrutura da precificação (adicionar/remover item, campo, custo,
  # empreendimento) — submete o form principal com structure_action (ver PricingStructure).
  def structure_button(label, value, editable:, css: "btn btn-ghost btn-xs text-primary", confirm: nil)
    tag.button(label, type: "submit", name: "structure_action", value: value, class: css, disabled: !editable,
      data: ({ turbo_confirm: confirm } if confirm))
  end

  # Sugestões pro campo de município (datalist): municípios do KMZ e os citados nos achados.
  def municipality_suggestions(conversation)
    from_kmz = Array(conversation.geospatial_result&.municipalities).map { |m| "#{m['name']}/#{m['uf']}" }
    from_findings = conversation.project_findings.active.where(field: "municipios").pluck(:value)
    (from_kmz + from_findings).map(&:strip).compact_blank.uniq.first(30)
  end

  # 2.25 → "2h15"; 0.5 → "30 min"
  def hours_label(hours)
    minutes = (hours.to_f * 60).round
    return "#{minutes} min" if minutes < 60

    "#{minutes / 60}h#{(minutes % 60).nonzero?&.to_s&.rjust(2, '0')}"
  end

  # Valor de campo numérico sem zeros à toa (0.25 e não 0.2500) — esforço por unidade tem 4 casas.
  def decimal_input(value)
    value && value.to_d.round(4).to_s("F").sub(/\.?0+\z/, "")
  end

  def decimal_label(value)
    number_with_delimiter(value.to_f.round(1), delimiter: ".", separator: ",").sub(/,0\z/, "")
  end

  # Texto do deslocamento diário até a hospedagem — mesma conta de FieldCampaign#effective_days
  # (o pricing_preview_controller.js refaz ao vivo, mesmo texto).
  def commute_note(campaign, pricing)
    notes = []
    if campaign.daily_commute_hours.positive?
      text = "Deslocamento de #{hours_label(campaign.commute_hours)} por trecho: #{decimal_label(campaign.productive_hours)}h úteis na jornada de " \
             "#{FieldCampaign::WORKDAY_HOURS}h → #{decimal_label(campaign.days)} → #{decimal_label(campaign.effective_days)} dias em campo"
      text += " (+#{decimal_label(campaign.extra_days)}; as diárias da equipe do item crescem junto)" if campaign.extra_days.positive?
      notes << tag.span("#{text}.", class: "text-base-content/60")
    end
    if campaign.commute_warning?
      notes << tag.span(" Mais de #{FieldCampaign::COMMUTE_WARNING_HOURS}h por trecho — ir e voltar todo dia é inviável; procure hospedagem mais perto da área ou alojamento.", class: "text-warning")
    end
    if campaign.lodging_pending?
      notes << tag.span(" Hospedagem não escolhida — usando #{brl(pricing.lodging_per_person_per_night)}/noite padrão.", class: "text-warning")
    end
    safe_join(notes)
  end

  PricingCheck = Data.define(:label, :tab, :level)

  # Pendências da Tela de Precificação, numa lista só (2026-10, remodelagem: os avisos ficavam
  # espalhados pelos blocos e passavam despercebidos). Cada uma aponta pra aba onde se resolve.
  # Nenhuma trava a aprovação — é o que vale conferir antes.
  def pricing_checks(proposal, pricing, items)
    checks = []
    unpriced_people = pricing.proposal_professionals.map(&:professional).uniq
      .select { |pro| !pro.cost_in_bdi? && pro.rate_man_hour.zero? && pro.rate_daily.zero? }
    if unpriced_people.any?
      checks << PricingCheck.new(label: "#{pluralize(unpriced_people.size, 'profissional', plural: 'profissionais')} sem valor de HH/diária", tab: "equipe", level: :warning)
    end

    unpriced_costs = items.sum { |item| item.costs.count { |cost| cost["unit_value"].to_d.zero? && cost["quantity"].to_d.positive? } }
    checks << PricingCheck.new(label: "#{pluralize(unpriced_costs, 'custo', plural: 'custos')} sem valor unitário", tab: "itens", level: :warning) if unpriced_costs.positive?

    pending_lodging = items.flat_map(&:field_campaigns).count(&:lodging_pending?)
    checks << PricingCheck.new(label: "#{pluralize(pending_lodging, 'campo', plural: 'campos')} sem hospedagem escolhida", tab: "itens", level: :warning) if pending_lodging.positive?
    checks << PricingCheck.new(label: "Distância sugere viagem aérea", tab: "itens", level: :warning) if pricing.long_distance?
    checks.concat(field_days_checks(pricing, items))

    if pricing.payment_percentage_total != 100
      checks << PricingCheck.new(label: "Desembolso soma #{pricing.payment_percentage_total.to_s('F').sub(/\.0\z/, '')}%", tab: "pagamento", level: :warning)
    end
    if pricing.price_presentation != "total" && proposal.price_presentation_mode != pricing.price_presentation
      checks << PricingCheck.new(label: "Quadro de preço não sai como escolhido", tab: "pagamento", level: :warning)
    end
    checks << PricingCheck.new(label: "Sem cronograma", tab: "cronograma", level: :info) if pricing.schedule_items.none?
    checks
  end

  # Diárias da equipe × dias de campo, por item (2026-10, teste do fluxo completo: as duas coisas são
  # digitadas em lugares diferentes e nada as amarrava — 48 diárias na equipe com um campo de 2 dias
  # passava em silêncio). Diária pode cobrir os dias de viagem ou não, então vale qualquer valor entre
  # pessoas × dias em campo e pessoas × (dias em campo + viagem).
  def field_days_checks(pricing, items)
    lines_by_item = pricing.proposal_professionals.group_by { |line| line.pricing_item_id || items.first&.id }
    items.filter_map do |item|
      team_days = lines_by_item.fetch(item.id, []).sum(&:field_days)
      campaigns = item.field_campaigns
      min_days = campaigns.sum { |campaign| campaign.people * campaign.days }
      # Viagem e deslocamento entram sozinhos (PricingItem#days_factor): as diárias digitadas são só
      # os dias EM CAMPO, então o esperado é pessoas × dias.
      max_days = min_days

      if campaigns.any? && team_days.zero?
        PricingCheck.new(label: "#{item.name}: tem campo, mas ninguém da equipe com diárias", tab: "itens", level: :warning)
      elsif campaigns.empty? && team_days.positive?
        PricingCheck.new(label: "#{item.name}: #{decimal_label(team_days)} diárias e nenhum campo (sem logística)", tab: "itens", level: :info)
      elsif campaigns.any? && (team_days < min_days || team_days > max_days)
        range = min_days == max_days ? decimal_label(min_days) : "#{decimal_label(min_days)} a #{decimal_label(max_days)}"
        PricingCheck.new(label: "#{item.name}: #{decimal_label(team_days)} diárias na equipe, #{range} pessoa-dias nos campos", tab: "itens", level: :warning)
      end
    end
  end
end
