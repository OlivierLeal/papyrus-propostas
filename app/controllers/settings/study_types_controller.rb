module Settings
  class StudyTypesController < BaseController
    before_action :set_study_type, only: %i[ edit update destroy ]

    def index
      @study_types = StudyType.order(:name)
    end

    def new
      @study_type = StudyType.new
    end

    def create
      @study_type = StudyType.new(study_type_params)

      if @study_type.save
        redirect_to settings_study_types_path, notice: "Tipo de estudo criado."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @study_type.update(study_type_params)
        redirect_to settings_study_types_path, notice: "Tipo de estudo atualizado."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @study_type.destroy
      redirect_to settings_study_types_path, notice: "Tipo de estudo removido."
    end

    private
      def set_study_type
        @study_type = StudyType.find(params[:id])
      end

      def study_type_params
        params.require(:study_type).permit(:name, :code, :description)
      end
  end
end
