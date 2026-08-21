require "test_helper"
require "benchmark"

class Rag::OcrTest < ActiveSupport::TestCase
  # PDF de imagem pura, sem camada de texto — o mesmo caso do "Print To PDF" que domina os
  # anexos do acervo. Está versionado para o teste não depender de gerar imagem na hora.
  FIXTURE = Rails.root.join("test/fixtures/files/scanned_sample.pdf")

  setup { skip "tesseract/pdftoppm não instalados" unless Rag::Ocr.available? }

  test "o PDF de fixture realmente não tem camada de texto" do
    result = Rag::TextExtractor.new(FIXTURE).call

    assert_equal :needs_ocr, result.status, "sem OCR, este arquivo não rende texto nenhum"
  end

  test "reconhece o texto da imagem" do
    pages = Rag::Ocr.new(FIXTURE).call

    assert_equal 1, pages.size
    assert_match(/PAPYRUS/i, pages.first)
    assert_match(/cetaceos/i, pages.first)
  end

  test "TextExtractor recupera o documento quando o OCR está ligado" do
    result = Rag::TextExtractor.new(FIXTURE, ocr: true).call

    assert result.ok?
    assert result.from_ocr?, "o status precisa registrar que o texto veio de OCR"
    assert_match(/CONSULTORIA AMBIENTAL/i, result.text)
  end

  test "sem a flag, o OCR não roda e o documento fica pendente" do
    result = Rag::TextExtractor.new(FIXTURE).call

    assert result.needs_ocr?
    assert_empty result.text
  end

  test "a segunda chamada vem do cache" do
    Rag::Ocr.new(FIXTURE).call

    elapsed = Benchmark.realtime { Rag::Ocr.new(FIXTURE).call }

    assert_operator elapsed, :<, 0.5, "OCR repetido deve sair do cache, não do tesseract"
  end
end
