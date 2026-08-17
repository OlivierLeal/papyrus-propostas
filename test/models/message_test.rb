require "test_helper"

class MessageTest < ActiveSupport::TestCase
  test "to_llm content excludes kmz attachments (geoespacial, a IA não lê)" do
    message = messages(:reviewing_setup_message)
    message.attachments.attach(
      io: StringIO.new("conteúdo kmz"), filename: "area.kmz", content_type: "application/vnd.google-earth.kmz",
      metadata: { kind: "kmz" }
    )
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    llm_message = message.to_llm

    attached_filenames = llm_message.content.attachments.map(&:filename)
    assert_includes attached_filenames, "tr.pdf"
    assert_not_includes attached_filenames, "area.kmz"
  end

  test "to_llm content includes every attachment when there is no kmz" do
    message = messages(:reviewing_setup_message)
    message.attachments.attach(
      io: StringIO.new("%PDF-1.4"), filename: "tr.pdf", content_type: "application/pdf",
      metadata: { kind: "tr" }
    )

    llm_message = message.to_llm

    assert_equal [ "tr.pdf" ], llm_message.content.attachments.map(&:filename)
  end
end
