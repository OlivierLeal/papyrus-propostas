module Settings
  class DashboardController < BaseController
    def index
      @study_types_count = StudyType.count
      @professionals_count = Professional.count
      @study_templates_count = StudyTemplate.count
      @logistics_configs_count = LogisticsConfig.count
    end
  end
end
