class Model < ApplicationRecord
  # acts_as_model só aceita UMA associação `chats:` (é só uma has_many de conveniência da gem,
  # não afeta FK nenhuma) — mantém a original (:conversations, já em uso no projeto) e acrescenta
  # general_chats à parte, já que Model é catálogo compartilhado entre os dois chats (ver CLAUDE.md).
  acts_as_model chats: :conversations
  has_many :general_chats
end
