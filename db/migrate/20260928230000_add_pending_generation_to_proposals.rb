# Geração da proposta que espera equipe/cronograma ficarem prontos (2026-09-28, pedido do
# consultor: "não faz sentido ter a proposta sem essas informações e depois pedir de novo").
# { "waiting" => ["team", "schedule", "key_points"], "requested_at" => ISO8601 } enquanto houver
# sugestão em segundo plano; vazio quando não há nada esperando. Ver
# GenerateProposalDocumentTool.background_task_finished!.
class AddPendingGenerationToProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :proposals, :pending_generation, :jsonb, null: false, default: {}
  end
end
