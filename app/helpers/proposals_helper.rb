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
  def pricing_number_field(builder, attribute, prefix: nil, suffix: nil, disabled: false, **options)
    tag.label(class: "input input-sm w-full #{'input-disabled' if disabled}") do
      safe_join([
        (tag.span(prefix, class: "text-base-content/40 text-xs") if prefix),
        builder.number_field(attribute, disabled: disabled, autocomplete: "off", class: "grow text-right", **options),
        (tag.span(suffix, class: "text-base-content/40 text-xs whitespace-nowrap") if suffix)
      ].compact)
    end
  end
end
