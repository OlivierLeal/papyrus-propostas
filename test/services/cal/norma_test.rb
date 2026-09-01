require "test_helper"

module Cal
  class NormaTest < ActiveSupport::TestCase
    test "from_api parses the .NET AJAX date format" do
      norma = Cal::Norma.from_api("DataPromulgacao" => "/Date(1455328800000)/")
      assert_equal Date.new(2016, 2, 13), norma.data_promulgacao
    end

    test "from_api tolerates a missing or unparseable date without raising" do
      assert_nil Cal::Norma.from_api("DataPromulgacao" => nil).data_promulgacao
      assert_nil Cal::Norma.from_api("DataPromulgacao" => "não é uma data").data_promulgacao
      assert_nil Cal::Norma.from_api({}).data_promulgacao
    end

    test "referencia joins the fields that are present, in order" do
      norma = Cal::Norma.from_api(
        "Codigo" => "NL7484", "TipoNormaENumeroEAnoPromulgacao" => "Portaria  11292/16",
        "OrgaoNome" => "INEMA", "AmbitoNome" => "Estadual"
      )

      assert_equal "NL7484 — Portaria 11292/16, INEMA, Estadual (CAL/Ius Natura)", norma.referencia
    end

    test "referencia degrades gracefully when orgao/ambito are missing" do
      norma = Cal::Norma.from_api("Codigo" => "NL1", "TipoNormaENumeroEAnoPromulgacao" => "Lei 1/20")
      assert_equal "NL1 — Lei 1/20 (CAL/Ius Natura)", norma.referencia
    end
  end
end
