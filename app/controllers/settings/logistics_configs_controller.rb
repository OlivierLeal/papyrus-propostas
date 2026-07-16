module Settings
  class LogisticsConfigsController < BaseController
    before_action :set_logistics_config, only: %i[ edit update destroy ]

    def index
      @logistics_configs = LogisticsConfig.order(:name)
    end

    def new
      @logistics_config = LogisticsConfig.new(active: true)
    end

    def create
      @logistics_config = LogisticsConfig.new(logistics_config_params)

      if @logistics_config.save
        redirect_to settings_logistics_configs_path, notice: "Parâmetro de logística criado."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
    end

    def update
      if @logistics_config.update(logistics_config_params)
        redirect_to settings_logistics_configs_path, notice: "Parâmetro de logística atualizado."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      @logistics_config.destroy
      redirect_to settings_logistics_configs_path, notice: "Parâmetro de logística removido."
    end

    private
      def set_logistics_config
        @logistics_config = LogisticsConfig.find(params[:id])
      end

      def logistics_config_params
        params.require(:logistics_config).permit(
          :name, :rental_per_day, :fuel_price_per_liter, :lodging_per_day, :meal_per_day, :active
        )
      end
  end
end
