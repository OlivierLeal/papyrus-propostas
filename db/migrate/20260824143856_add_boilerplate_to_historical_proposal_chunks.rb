class AddBoilerplateToHistoricalProposalChunks < ActiveRecord::Migration[8.1]
  def change
    # Trecho que se repete em praticamente toda proposta da Papyrus (obrigações das partes,
    # validade, prazo, condições de pagamento). Não distingue um job de outro, mas competia em pé
    # de igualdade com o escopo na busca por projetos semelhantes — ver Rag::BoilerplateDetector.
    add_column :historical_proposal_chunks, :boilerplate, :boolean, default: false, null: false
    add_index :historical_proposal_chunks, :boilerplate
  end
end
