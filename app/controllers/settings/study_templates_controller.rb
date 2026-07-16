module Settings
  class StudyTemplatesController < BaseController
    before_action :set_study_template, only: %i[ edit update destroy ]

    def index
      @study_templates = StudyTemplate.includes(:study_type, :professional).order("study_types.name", "professionals.name").references(:study_type, :professional)
    end

    def new
      @study_template = StudyTemplate.new
    end

    def create
      @study_template = StudyTemplate.new(study_template_params)

      if @study_template.save
        redirect_to settings_study_templates_path, notice: "Template de estudo criado."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @study_template.update(study_template_params)
        redirect_to settings_study_templates_path, notice: "Template de estudo atualizado."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @study_template.destroy
      redirect_to settings_study_templates_path, notice: "Template de estudo removido."
    end

    private
      def set_study_template
        @study_template = StudyTemplate.find(params[:id])
      end

      def study_template_params
        params.require(:study_template).permit(
          :study_type_id, :professional_id, :deliverable_name, :hours_office_default, :hours_field_default
        )
      end
  end
end
