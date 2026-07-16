class StudyType < ApplicationRecord
  has_many :study_templates, dependent: :destroy

  validates :name, presence: true
  validates :code, presence: true, uniqueness: true
end
