module SettingsHelper
  # Classe do campo com destaque de erro (daisyUI 5: input-error/select-error/textarea-error).
  def settings_field_class(record, attribute, base: "input")
    [ base, "w-full", ("#{base}-error" if record.errors[attribute].any?) ].compact.join(" ")
  end

  def settings_field_error(record, attribute)
    return if record.errors[attribute].none?

    tag.p(record.errors.full_messages_for(attribute).to_sentence, class: "label text-error")
  end
end
