class Conversation < ApplicationRecord
  acts_as_chat

  STATUSES = %w[setup processing reviewing pricing completed].freeze

  belongs_to :user
  belongs_to :study_type

  validates :client_name, presence: true
  validates :status, inclusion: { in: STATUSES }
end
