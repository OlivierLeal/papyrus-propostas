class AddDocxFilenameOverrideToProposals < ActiveRecord::Migration[8.1]
  def change
    # Nome de arquivo que o consultor ditou no chat ("o arquivo tem que se chamar X"). Fica na
    # proposta, não na geração: ele está dizendo como o ARQUIVO se chama, não como aquela versão
    # específica deveria se chamar — então vale para as gerações seguintes também.
    add_column :proposals, :docx_filename_override, :string
  end
end
