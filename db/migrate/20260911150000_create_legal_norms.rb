class CreateLegalNorms < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_norms do |t|
      t.string :codigo, null: false
      t.string :anexo_id
      t.string :tipo_e_numero
      t.string :orgao
      t.string :ambito
      t.string :tema
      t.string :escopo
      t.text :assunto
      t.date :data_promulgacao
      t.string :status
      t.string :referencia
      t.text :full_text
      t.boolean :ocr_used, default: false, null: false

      t.timestamps
    end

    add_index :legal_norms, :codigo, unique: true
  end
end
