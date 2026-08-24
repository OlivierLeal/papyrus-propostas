# Liga uma divergência aos achados que discordam entre si.
class ProjectConflictFinding < ApplicationRecord
  belongs_to :project_conflict
  belongs_to :project_finding
end
