class CreateLegalNormChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_norm_chunks do |t|
      t.references :legal_norm, null: false, foreign_key: true, index: false

      t.integer :position, null: false
      t.string :section_number
      t.string :section_title
      t.text :content, null: false
      t.integer :token_count, default: 0, null: false

      # 1024 dimensões = cohere.embed-multilingual-v3 no Bedrock sa-east-1 (Rag::Embedder).
      t.vector :embedding, limit: Rag::Embedder::DIMENSIONS
      t.string :embedding_model
      t.datetime :embedded_at

      t.timestamps
    end

    add_index :legal_norm_chunks, [ :legal_norm_id, :position ], unique: true,
      name: "index_legal_norm_chunks_on_norm_and_position"

    add_index :legal_norm_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops,
      name: "index_legal_norm_chunks_on_embedding"
  end
end
