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
end
