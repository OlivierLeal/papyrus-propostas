class CreateHistoricalProposalChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :historical_proposal_chunks do |t|
      t.references :historical_proposal, null: false, foreign_key: true, index: false

      t.integer :position, null: false
      t.string :section_number
      t.string :section_title
      t.text :content, null: false
      t.integer :token_count, default: 0, null: false

      # LGPD e seção 5 do CLAUDE.md: permite excluir da recuperação trechos com dado
      # identificável, e distinguir trecho que fala de preço (referência, nunca insumo de cálculo).
      t.boolean :sensitive, default: false, null: false
      t.boolean :contains_pricing, default: false, null: false
      t.string :sensitivity_reasons, array: true, default: []

      # 1024 dimensões = cohere.embed-multilingual-v3 no Bedrock sa-east-1.
      t.vector :embedding, limit: Rag::Embedder::DIMENSIONS
      t.string :embedding_model
      t.datetime :embedded_at

      t.timestamps
    end

    add_index :historical_proposal_chunks, [ :historical_proposal_id, :position ], unique: true,
      name: "index_hp_chunks_on_proposal_and_position"

    # HNSW dá busca aproximada rápida; cosine é a distância que combina com embedding
    # normalizado, que é o que o Cohere devolve.
    add_index :historical_proposal_chunks, :embedding, using: :hnsw, opclass: :vector_cosine_ops,
      name: "index_hp_chunks_on_embedding"
  end
end
