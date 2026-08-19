class MakeConversationsStudyTypeOptional < ActiveRecord::Migration[8.1]
  def change
    # O tipo de estudo deixa de ser escolhido no setup — a IA identifica lendo a TR
    # (ver ProcessTrJob). Até isso acontecer (ou se não houver TR), fica null.
    change_column_null :conversations, :study_type_id, true
  end
end
