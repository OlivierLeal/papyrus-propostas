class AddOriginToHistoricalProposals < ActiveRecord::Migration[8.1]
  def change
    # Distingue o que veio do acervo em disco (escrito por humanos, revisado, assinado) do que
    # o próprio sistema produziu. Sem isso, em alguns meses não há como saber se um trecho
    # recuperado é uma proposta real ou algo que a IA escreveu e ninguém conferiu.
    add_column :historical_proposals, :origin, :string, null: false, default: "acervo"
    add_index :historical_proposals, :origin

    # Proposta gerada pelo sistema aponta para a conversa que a produziu.
    add_reference :historical_proposals, :conversation, foreign_key: true, null: true
  end
end
