# Junta linhas repetidas da equipe (mesma pessoa no MESMO item) nas propostas NÃO aprovadas —
# o que Proposal#apply_team_lines! passou a fazer na sugestão da IA (2026-09-30) só vale pra
# sugestões novas. Soma HH/diárias e junta os entregáveis; recalcula o preço (o custo da soma é o
# mesmo das linhas separadas, só o arredondamento do acréscimo de deslocamento pode mudar centavos).
#
#   bin/rails runner script/maintenance/merge_duplicate_team_lines.rb           # só mostra
#   bin/rails runner script/maintenance/merge_duplicate_team_lines.rb --apply   # aplica
apply = ARGV.include?("--apply")

ProjectPricing.joins(:proposal).where.not(proposals: { status: "approved" }).find_each do |pricing|
  groups = pricing.proposal_professionals.includes(:professional).group_by { |line| [ line.professional_id, line.pricing_item_id ] }
  duplicates = groups.values.select { |lines| lines.size > 1 }
  next if duplicates.empty?

  before = pricing.total_value
  ActiveRecord::Base.transaction do
    duplicates.each do |lines|
      keep, *rest = lines.sort_by(&:id)
      names = lines.map(&:deliverable_name).uniq { |name| name.strip.downcase }
      puts "proposta #{pricing.proposal_id}: #{keep.professional.name} × #{lines.size} → #{names.join('; ').truncate(120)}"
      next unless apply

      keep.update!(deliverable_name: names.join("; ").truncate(255),
                   man_hours: lines.sum(&:man_hours), field_days: lines.sum(&:field_days))
      rest.each(&:destroy!)
    end
    next unless apply

    pricing.recalculate!
    puts "  total: #{before} → #{pricing.reload.total_value}"
  end
end
puts apply ? "Aplicado." : "Nada alterado (rode com --apply pra aplicar)."
