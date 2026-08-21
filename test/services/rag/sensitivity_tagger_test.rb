require "test_helper"

class Rag::SensitivityTaggerTest < ActiveSupport::TestCase
  test "marca valor em reais como conteúdo de preço" do
    tags = Rag::SensitivityTagger.new("O valor total dos serviços é de R$ 148.500,00.").call

    assert tags.contains_pricing
    assert tags.sensitive
    assert_includes tags.reasons, "money"
  end

  test "marca registro de conselho profissional como dado identificável" do
    tags = Rag::SensitivityTagger.new("Maria Nogueira | Bióloga | CRBio: 36.780/08-D").call

    assert tags.sensitive
    assert_includes tags.reasons, "professional_registration"
    assert_not tags.contains_pricing
  end

  test "marca CNPJ e e-mail institucionais" do
    tags = Rag::SensitivityTagger.new("CNPJ: 07.946.358/0001-50 — bemvindo@somospapyrus.com.br").call

    assert tags.sensitive
    assert_includes tags.reasons, "cnpj"
    assert_includes tags.reasons, "email"
  end

  test "texto técnico sem dado pessoal nem valor não é marcado" do
    tags = Rag::SensitivityTagger.new("O diagnóstico do meio biótico contemplará fauna e flora.").call

    assert_not tags.sensitive
    assert_not tags.contains_pricing
    assert_empty tags.reasons
  end
end
