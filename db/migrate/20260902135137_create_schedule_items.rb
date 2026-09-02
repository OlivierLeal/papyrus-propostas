class CreateScheduleItems < ActiveRecord::Migration[8.1]
  def change
    create_table :schedule_items do |t|
      t.references :project_pricing, null: false, foreign_key: true
      t.string :schedule_type, null: false # "servico" | "implantacao" — ver ScheduleItem::SCHEDULE_TYPES
      t.string :phase_name, null: false
      t.string :activity_name, null: false
      t.integer :start_period, null: false # 1-based: semana (servico) ou mês (implantacao)
      t.integer :duration_periods, null: false
      t.boolean :milestone, default: false, null: false
      # Ordem de exibição — grupos de fase são linhas CONSECUTIVAS com o mesmo phase_name (mesma
      # convenção de "Fase:" nos produtos, GenerateProposalDocumentTool#build_tables), não um flag
      # "é cabeçalho" à parte.
      t.integer :position, null: false

      t.timestamps
    end

    add_index :schedule_items, [ :project_pricing_id, :position ]
  end
end
