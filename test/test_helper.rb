require "simplecov"
SimpleCov.start "rails" do
  skip "/test/"
  skip "/app/channels/"
  skip "app/jobs/application_job.rb"

  # O profile "rails" não conhece app/services nem app/tools — sem isso os dois caem em
  # "Ungrouped" no relatório em vez de aparecerem como uma seção própria.
  group "Services", "app/services"
  group "Tools", "app/tools"
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/ai_stub_helper"

module ActiveSupport
  class TestCase
    # Desligado (era :number_of_processors) — o SimpleCov precisa de um processo só pra somar a
    # cobertura de forma confiável; os testes daqui não são numerosos o bastante pra sentir falta.
    parallelize(workers: 1)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include ActiveJob::TestHelper
    include AiStubHelper

    # Add more helper methods to be used by all tests here...
  end
end
