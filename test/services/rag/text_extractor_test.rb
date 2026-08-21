require "test_helper"

class Rag::TextExtractorTest < ActiveSupport::TestCase
  test "extrai o texto de um DOCX real, separando as células de tabela" do
    result = Rag::TextExtractor.new(Rails.root.join("app/templates/docx/proposta_tecnica_comercial.docx")).call

    assert result.ok?
    assert result.text.present?
    assert_equal 1, result.page_count, "DOCX não é paginado"
  end

  test "classifica PDF escaneado como needs_ocr em vez de devolver ruído" do
    # 10 páginas com um caractere cada é o que o pdftotext devolve de um PDF de imagem.
    result = classify(Array.new(10) { "1\n" })

    assert result.needs_ocr?
    assert_operator result.chars_per_page, :<, Rag::TextExtractor::MIN_CHARS_PER_PAGE
  end

  test "remove o cabeçalho e rodapé que se repetem em todas as páginas" do
    footer = "Rua Esperança, 97, Portão - Lauro de Freitas - Bahia"
    pages = (1..5).map { |i| "#{footer}\nConteúdo exclusivo da página #{i}. #{'texto ' * 40}\n#{footer}\n" }

    result = strip(pages)

    assert_not_includes result.text, footer
    assert_includes result.text, "Conteúdo exclusivo da página 3"
  end

  test "parágrafos dentro de uma célula de tabela não grudam" do
    # Regressão: uma célula com vários parágrafos (listas de diagnóstico ambiental moram
    # assim no acervo) era concatenada sem separador e inventava tokens inexistentes —
    # "Meio físicoÁreas de influênciaClima".
    xml = <<~XML
      <w:document xmlns:w="x"><w:body><w:tbl><w:tr><w:tc>
        <w:p><w:r><w:t>Meio físico</w:t></w:r></w:p>
        <w:p><w:r><w:t>Áreas de influência</w:t></w:r></w:p>
        <w:p><w:r><w:t>Clima</w:t></w:r></w:p>
      </w:tc><w:tc><w:p><w:r><w:t>AII</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>
    XML

    text = extract_docx_from(xml)

    assert_not_includes text, "físicoÁreas", "as palavras não podem colar"
    assert_includes text, "Meio físico · Áreas de influência · Clima"
    assert_includes text, "| AII", "colunas continuam separadas"
  end

  test "formato sem suporte é reportado, não estoura" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "planilha.xlsx")
      File.write(path, "x")

      assert_equal :unsupported, Rag::TextExtractor.new(path).call.status
    end
  end

  test "PDF corrompido vira ExtractionError para não derrubar o lote" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "corrompido.pdf")
      File.write(path, "isto não é um PDF")

      assert_raises(Rag::TextExtractor::ExtractionError) { Rag::TextExtractor.new(path).call }
    end
  end

  private

  # Exercita classificação e limpeza sem precisar versionar um PDF binário só para o teste.
  def extractor = Rag::TextExtractor.new("acervo.pdf")

  # Exercita a conversão do XML do DOCX sem precisar montar um .docx real no disco.
  def extract_docx_from(xml) = Rag::TextExtractor.new("acervo.docx").send(:docx_text, xml)

  def classify(pages) = extractor.send(:build_result, pages)

  def strip(pages) = extractor.send(:build_result, extractor.send(:strip_boilerplate, pages))
end
