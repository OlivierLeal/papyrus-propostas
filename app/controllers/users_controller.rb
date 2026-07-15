class UsersController < ApplicationController
  before_action :set_user, only: %i[ edit update destroy ]

  def index
    @users = User.order(:name)
  end

  def new
    @user = User.new
  end

  def create
    @user = User.new(user_params_for_create)

    if @user.save
      redirect_to users_path, notice: "Usuário criado."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @user.update(user_params_for_update)
      redirect_to users_path, notice: "Usuário atualizado."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @user == current_user
      redirect_to users_path, alert: "Você não pode remover seu próprio usuário."
      return
    end

    @user.destroy
    redirect_to users_path, notice: "Usuário removido."
  end

  private
    def set_user
      @user = User.find(params[:id])
    end

    def user_params_for_create
      params.require(:user).permit(:name, :email_address, :password, :password_confirmation)
    end

    def user_params_for_update
      params.require(:user).permit(:name, :email_address)
    end
end
