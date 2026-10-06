# TR do estudo (Termo de Referência do órgão) encontrado pelo sistema no CAL ou na internet — ou
# indicado pelo consultor entre os arquivos do chat — quando o cliente não mandou um na Tela de
# Setup. Nasce "pending" com um card no chat; só vira o TR da proposta (Anexo I do .docx e base do
# ProcessTrJob) quando o consultor aceita.
class CreateTermOfReferenceCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :term_of_reference_candidates do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :source, null: false
      t.string :title, null: false
      t.string :url
      t.string :norm_code
      t.text :reason
      t.string :status, null: false, default: "pending"
      t.string :error
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.timestamps
    end
  end
end
