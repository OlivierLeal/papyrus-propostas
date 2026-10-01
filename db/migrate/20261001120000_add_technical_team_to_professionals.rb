# Quadro EQUIPE TÉCNICA da proposta só com quem faz parte da equipe técnica (Charlene, 2026-10-01: tirou
# do quadro o apoio administrativo e a revisão/formatação). Continuam na precificação — só não aparecem
# no .docx. Junto, a habilitação do Molina ("Biólogo", também pedido dela).
class AddTechnicalTeamToProfessionals < ActiveRecord::Migration[8.1]
  def up
    add_column :professionals, :technical_team, :boolean, null: false, default: true
    execute "UPDATE professionals SET technical_team = false WHERE name IN ('Carolene Marchant', 'Melissa Oliveira')"
    execute "UPDATE professionals SET specialties = 'Assessor Ambiental Sênior. Biólogo.' WHERE name = 'Antônio Molina'"
  end

  def down
    remove_column :professionals, :technical_team
  end
end
