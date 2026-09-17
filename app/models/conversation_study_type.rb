# Junção simples entre Conversation e StudyType (2026-09) — uma proposta pode exigir vários
# estudos ao mesmo tempo, ou nenhum (só acompanhamento). Sem lógica própria: quem decide QUAIS
# tipos associar é Conversation#assign_study_types_from_findings! (a partir dos achados de
# ET/TR) ou o consultor direto na tela.
class ConversationStudyType < ApplicationRecord
  belongs_to :conversation
  belongs_to :study_type
end
