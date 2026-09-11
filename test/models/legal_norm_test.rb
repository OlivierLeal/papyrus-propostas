require "test_helper"

class LegalNormTest < ActiveSupport::TestCase
  test "requires a codigo" do
    legal_norm = LegalNorm.new(codigo: nil)

    assert_not legal_norm.valid?
    assert_includes legal_norm.errors[:codigo], "não pode ficar em branco"
  end

  test "codigo must be unique" do
    LegalNorm.create!(codigo: "NL9924")
    duplicate = LegalNorm.new(codigo: "NL9924")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:codigo], "já está em uso"
  end
end
