class CreateKnowledgeNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_notes do |t|
      # De onde a nota saiu — permite auditar depois "por que o sistema acha isso?".
      t.references :conversation, null: false, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }

      t.string :category, null: false
      t.string :client_name
      t.text :content, null: false
      # Trecho da conversa que originou a nota, para o consultor julgar sem reabrir o chat.
      t.text :context

      # Nota só é consultável depois que um humano confirma. Conhecimento gerado por IA que
      # entra no índice sem revisão volta depois como se fosse fato da Papyrus — e a citação
      # faria uma invenção parecer verificável.
      t.string :status, null: false, default: "pending"
      t.datetime :approved_at

      t.vector :embedding, limit: Rag::Embedder::DIMENSIONS
      t.string :embedding_model
      t.datetime :embedded_at

      t.timestamps
    end

    add_index :knowledge_notes, [ :status, :client_name ]
    add_index :knowledge_notes, :category
    add_index :knowledge_notes, :embedding, using: :hnsw, opclass: :vector_cosine_ops,
      name: "index_knowledge_notes_on_embedding"
  end
end
