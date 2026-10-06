require "test_helper"

class TermOfReferenceDownloaderTest < ActiveSupport::TestCase
  test "só baixa de endereço público por http(s)" do
    error = assert_raises(TermOfReferenceAnnex::Downloader::Error) { TermOfReferenceAnnex::Downloader.call("http://127.0.0.1/tr.pdf") }
    assert_equal "Endereço não permitido.", error.message
    assert_raises(TermOfReferenceAnnex::Downloader::Error) { TermOfReferenceAnnex::Downloader.call("http://192.168.0.10/tr.pdf") }
    assert_raises(TermOfReferenceAnnex::Downloader::Error) { TermOfReferenceAnnex::Downloader.call("ftp://orgao.gov.br/tr.pdf") }
  end

  test "aceita PDF e Word, recusa página HTML" do
    downloader = TermOfReferenceAnnex::Downloader.new("https://orgao.gov.br/x")
    pdf = Net::HTTPOK.new("1.1", "200", "OK").tap { |r| r["content-type"] = "application/pdf" }
    html = Net::HTTPOK.new("1.1", "200", "OK").tap { |r| r["content-type"] = "text/html" }

    result = downloader.send(:result_for, URI("https://orgao.gov.br/portaria-tr.pdf"), pdf, "%PDF-1.4")
    assert_equal [ "portaria-tr.pdf", "application/pdf" ], [ result.filename, result.content_type ]
    assert_raises(TermOfReferenceAnnex::Downloader::Error) { downloader.send(:result_for, URI("https://orgao.gov.br/tr"), html, "<html>") }
  end
end
