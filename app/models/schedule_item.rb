# Uma linha (fase + atividade) do cronograma de uma proposta — Gantt no .docx gerado, ver
# CLAUDE.md seção 8. Sempre uma ATIVIDADE, nunca uma linha de fase separada: o renderer do docx
# (ScheduleTableBuilder) detecta troca de phase_name entre linhas consecutivas (por `position`) e
# insere a linha de fase sozinho, mesma convenção de "Fase:" nos produtos
# (GenerateProposalDocumentTool#build_tables).
class ScheduleItem < ApplicationRecord
  belongs_to :project_pricing

  # "servico" = cronograma do Serviço da Papyrus (semanas). "implantacao" = cronograma de
  # Implantação do Empreendimento do cliente (meses — pode durar anos, semana ficaria ilegível).
  SCHEDULE_TYPES = %w[servico implantacao].freeze

  SCHEDULE_TYPE_LABELS = {
    "servico" => "Cronograma do Serviço (Papyrus)",
    "implantacao" => "Cronograma de Implantação do Empreendimento"
  }.freeze

  PERIOD_UNIT_LABELS = { "servico" => "Semana", "implantacao" => "Mês" }.freeze

  validates :schedule_type, inclusion: { in: SCHEDULE_TYPES }
  validates :phase_name, :activity_name, presence: true
  validates :start_period, :duration_periods, :position,
    presence: true, numericality: { only_integer: true }
  validates :start_period, numericality: { greater_than_or_equal_to: 1 }
  validates :duration_periods, numericality: { greater_than_or_equal_to: 1 }

  scope :for_type, ->(type) { where(schedule_type: type).order(:position) }
end
