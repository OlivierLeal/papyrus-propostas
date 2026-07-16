module Settings
  class ProfessionalsController < BaseController
    before_action :set_professional, only: %i[ edit update destroy ]

    def index
      @professionals = Professional.order(:name)
    end

    def new
      @professional = Professional.new(active: true)
    end

    def create
      @professional = Professional.new(professional_params)

      if @professional.save
        redirect_to settings_professionals_path, notice: "Profissional criado."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @professional.update(professional_params)
        redirect_to settings_professionals_path, notice: "Profissional atualizado."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @professional.destroy
      redirect_to settings_professionals_path, notice: "Profissional removido."
    end

    private
      def set_professional
        @professional = Professional.find(params[:id])
      end

      def professional_params
        params.require(:professional).permit(
          :name, :role, :rate_office, :rate_field, :registration, :specialties, :active
        )
      end
  end
end
