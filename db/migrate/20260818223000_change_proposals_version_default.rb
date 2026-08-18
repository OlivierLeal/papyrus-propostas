class ChangeProposalsVersionDefault < ActiveRecord::Migration[8.1]
  def change
    # version passa a significar "quantas vezes o documento já foi gerado" — 0 = nunca gerado.
    # Não é retroativo: propostas já existentes mantêm o valor atual (ver GenerateProposalDocumentTool).
    change_column_default :proposals, :version, from: 1, to: 0
  end
end
