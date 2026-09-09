require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module PapyrusPropostas
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # Sem isso, Time.zone fica em UTC (default do Rails) — mas `created_at`/`updated_at` das
    # mensagens (e qualquer outro timestamp mostrado na tela) ficam com hora ADIANTADA 3h da
    # hora real do consultor (Brasil inteiro é UTC-3, sem horário de verão desde 2019 — "Brasilia"
    # é o nome amigável do Rails pra essa zona, TZInfo "America/Sao_Paulo"). Como
    # `time_zone_aware_attributes` já vem `true` por padrão (Rails 7+), só setar isso aqui já
    # corrige a exibição em qualquer view que usa `created_at` direto (ex.: `conversations/
    # _message.html.erb`), sem precisar converter timestamp por timestamp na view.
    config.time_zone = "Brasilia"
    # config.eager_load_paths << Rails.root.join("extras")

    # Internationalization
    config.i18n.default_locale = :'pt-BR'
    config.i18n.available_locales = [ :'pt-BR', :en ]
  end
end
