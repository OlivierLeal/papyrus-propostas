class AddDocumentSplitToProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :proposals, :document_split, :string, null: false, default: "combined"
  end
end
