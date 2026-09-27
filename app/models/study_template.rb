class StudyTemplate < ApplicationRecord
  belongs_to :study_type
  belongs_to :professional

  validates :deliverable_name, presence: true, uniqueness: { scope: [ :study_type_id, :professional_id ] }
  validates :man_hours_default, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :field_days_default, presence: true, numericality: { greater_than_or_equal_to: 0 }
end
