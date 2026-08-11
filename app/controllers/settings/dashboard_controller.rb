module Settings
  class DashboardController < BaseController
    def index
      @study_types_count = StudyType.count
      @professionals_count = Professional.count
      @study_templates_count = StudyTemplate.count
    end
  end
end
