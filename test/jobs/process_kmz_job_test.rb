require "test_helper"

class ProcessKmzJobTest < ActiveSupport::TestCase
  VALID_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <Polygon>
            <outerBoundaryIs>
              <LinearRing>
                <coordinates>-40.30,-14.85,0 -40.28,-14.85,0 -40.28,-14.83,0 -40.30,-14.83,0 -40.30,-14.85,0</coordinates>
              </LinearRing>
            </outerBoundaryIs>
          </Polygon>
        </Placemark>
      </Document>
    </kml>
  KML

  setup do
    @conversation = conversations(:processing_conversation)
  end

  test "marks kmz as skipped when there is no KMZ attachment" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })

    ProcessKmzJob.perform_now(@conversation.id)

    assert_equal "skipped", @conversation.reload.processing_step_status("kmz")
  end

  test "processes a valid KMZ and populates the geospatial result, including the sketch image" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz(VALID_KML)

    ProcessKmzJob.perform_now(@conversation.id)

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("kmz")

    result = @conversation.geospatial_result
    assert result.present?
    assert_in_delta 478.07, result.area_ha, 0.5
    assert_in_delta 8.75, result.perimeter_km, 0.05
    assert result.sketch_image.attached?
    assert_equal "image/svg+xml", result.sketch_image.content_type
  end

  test "marks kmz as failed and does not raise when the KMZ has no polygon" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz("isso não é um KML válido")

    ProcessKmzJob.perform_now(@conversation.id)

    assert_equal "failed", @conversation.reload.processing_step_status("kmz")
    assert_nil @conversation.geospatial_result
  end

  test "triggers GenerateSummaryJob once tr and comp_docs are already resolved" do
    @conversation.update!(processing_steps: { "tr" => "done", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })

    assert_enqueued_with(job: GenerateSummaryJob, args: [ @conversation.id ]) do
      ProcessKmzJob.perform_now(@conversation.id)
    end
  end

  private
    def attach_kmz(kml_content)
      message = @conversation.messages.create!(role: "user", content: "setup", internal: false)
      message.attachments.attach(
        io: StringIO.new(kml_content), filename: "area.kml", content_type: "application/vnd.google-earth.kml+xml",
        metadata: { kind: "kmz" }
      )
    end
end
