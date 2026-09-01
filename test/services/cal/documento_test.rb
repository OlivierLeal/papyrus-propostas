require "test_helper"

module Cal
  class DocumentoTest < ActiveSupport::TestCase
    class FakeClient
      attr_reader :calls

      def initialize(bytes:, content_type: "application/pdf")
        @bytes = bytes
        @content_type = content_type
        @calls = []
      end

      def download(path, referer:)
        @calls << { path: path, referer: referer }
        return nil if @bytes.nil?

        [ @bytes, @content_type ]
      end
    end

    test "texto downloads via the client and extracts the real PDF text" do
      bytes = Rails.root.join("test/fixtures/files/norma_sample.pdf").binread
      client = FakeClient.new(bytes: bytes)

      texto = Cal::Documento.new(client: client).texto("guid-123")

      assert texto.present?
      assert_equal "/UploadArquivo/ObterPdfPorNome?nome=guid-123", client.calls.sole[:path]
      assert_equal Cal::Normas::PAGE_URL, client.calls.sole[:referer]
    end

    test "texto returns nil when the client can't download anything" do
      client = FakeClient.new(bytes: nil)

      assert_nil Cal::Documento.new(client: client).texto("guid-123")
    end

    test "texto returns nil when the download isn't a PDF" do
      client = FakeClient.new(bytes: "<html>não é pdf</html>", content_type: "text/html")

      assert_nil Cal::Documento.new(client: client).texto("guid-123")
    end

    test "texto returns nil for a blank anexo_id, without calling the client" do
      client = FakeClient.new(bytes: "não importa")

      assert_nil Cal::Documento.new(client: client).texto(nil)
      assert_empty client.calls
    end

    test "texto truncates at MAX_TEXT_CHARS" do
      original = Cal::Documento::MAX_TEXT_CHARS
      Cal::Documento.send(:remove_const, :MAX_TEXT_CHARS)
      Cal::Documento.const_set(:MAX_TEXT_CHARS, 20)

      bytes = Rails.root.join("test/fixtures/files/norma_sample.pdf").binread
      texto = Cal::Documento.new(client: FakeClient.new(bytes: bytes)).texto("guid-123")

      assert_operator texto.length, :<=, 23 # truncate acrescenta "..."
    ensure
      Cal::Documento.send(:remove_const, :MAX_TEXT_CHARS)
      Cal::Documento.const_set(:MAX_TEXT_CHARS, original)
    end
  end
end
