class StudyType < ApplicationRecord
  has_many :study_templates, dependent: :destroy
  has_many :conversations, dependent: :restrict_with_error

  validates :name, presence: true
  validates :code, presence: true, uniqueness: true
end
