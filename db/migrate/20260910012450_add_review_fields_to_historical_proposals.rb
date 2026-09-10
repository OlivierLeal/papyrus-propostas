class AddReviewFieldsToHistoricalProposals < ActiveRecord::Migration[8.1]
  def change
    # Todo registro já existente (acervo em disco, IndexApprovedProposalJob) fica implicitamente
    # aprovado — nenhuma query de busca precisa passar a filtrar por review_status. Só o caminho
    # novo (LearnFromRevisedProposalTool) nasce "pending".
    add_column :historical_proposals, :review_status, :string, default: "approved", null: false

    # Texto extraído do anexo, só enquanto pending — a aprovação chunka isso e limpa o campo (ver
    # HistoricalProposal#approve!).
    add_column :historical_proposals, :pending_text, :text

    # Quem clicou "Guardar" no card — não é necessariamente quem anexou o arquivo no chat.
    add_reference :historical_proposals, :submitted_by, null: true, foreign_key: { to_table: :users }
  end
end
