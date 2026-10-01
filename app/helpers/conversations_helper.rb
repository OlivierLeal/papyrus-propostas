module ConversationsHelper
  # A numeração da proposta (Proposal#docx_numero_proposta) carrega o ano de 2 dígitos — pedido
  # do consultor pra deixar isso visível na tela também, já que o mesmo id (ex.: "098") volta a
  # aparecer em anos diferentes ("PTC26098" × "PTC25098" são propostas DIFERENTES) conforme o
  # uso do sistema acumula mais de um ano de histórico. Ano corrente e o anterior ganham seção
  # própria; o resto (mais de 1 ano) cai junto em "Anteriores" — só 3 grupos, não um por ano.
  def year_group_label(time)
    year_group_label_for(time.in_time_zone.year)
  end

  def year_group_label_for(year)
    current = Date.current.year
    year.to_i >= current - 1 ? year.to_i.to_s : "Anteriores"
  end
end
