class CreateProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :proposals do |t|
      t.references :conversation, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :content_json, null: false, default: {}
      t.string :pdf_url
      t.integer :version, null: false, default: 1
      t.string :status, null: false, default: "draft"

      t.timestamps
    end
  end
end
