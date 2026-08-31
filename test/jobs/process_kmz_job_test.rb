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

  # Achado num KMZ real em produção: linha de transmissão sem nenhum polígono — antes disso
  # existir, ProcessKmzJob marcava "failed" pra qualquer projeto que não fosse área poligonal.
  LINE_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <LineString>
            <coordinates>-40.30,-14.85,0 -40.29,-14.84,0 -40.28,-14.83,0</coordinates>
          </LineString>
        </Placemark>
      </Document>
    </kml>
  KML

  setup do
    @conversation = conversations(:processing_conversation)
  end

  test "marks kmz as skipped when there is no KMZ attachment" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })

    ProcessKmzJob.perform_now(@conversation.id)

    assert_equal "skipped", @conversation.reload.processing_step_status("kmz")
  end

  test "processes a valid KMZ and populates the geospatial result, falling back to the SVG croqui when Mapbox is unavailable" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz(VALID_KML)

    stub_mapbox_fetch(nil) { ProcessKmzJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("kmz")

    result = @conversation.geospatial_result
    assert result.present?
    assert_in_delta 478.07, result.area_ha, 0.5
    assert_in_delta 8.75, result.perimeter_km, 0.05
    assert result.area_image.attached?
    assert_equal "image/svg+xml", result.area_image.content_type
  end

  test "uses the real Mapbox map instead of the SVG croqui when it's available" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz(VALID_KML)

    stub_mapbox_fetch("fake-png-bytes") { ProcessKmzJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("kmz")

    result = @conversation.geospatial_result
    assert result.area_image.attached?
    assert_equal "image/png", result.area_image.content_type
    assert_equal "fake-png-bytes", result.area_image.download
  end

  test "marks kmz as failed and does not raise when the KMZ has no geometry at all" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz("isso não é um KML válido")

    ProcessKmzJob.perform_now(@conversation.id)

    assert_equal "failed", @conversation.reload.processing_step_status("kmz")
    assert_nil @conversation.geospatial_result
  end

  test "processes a KMZ with only a LineString (no polygon), computing length instead of area" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })
    attach_kmz(LINE_KML)

    stub_mapbox_fetch(nil) { ProcessKmzJob.perform_now(@conversation.id) }

    @conversation.reload
    assert_equal "done", @conversation.processing_step_status("kmz")

    result = @conversation.geospatial_result
    assert_equal "line", result.geometry_type
    assert_nil result.area_ha
    assert result.length_km.positive?
    assert result.area_image.attached? # croqui de linha (<polyline>), não trava a proposta
  end

  test "triggers GenerateSummaryJob once tr and comp_docs are already resolved" do
    @conversation.update!(processing_steps: { "et" => "done", "tr" => "skipped", "comp_docs" => "skipped", "kmz" => "pending", "summary" => "pending" })

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

    # Sem isso, ProcessKmzJob chamaria a Mapbox de verdade em todo teste (MAPBOX_API_KEY já vem
    # do .env em qualquer ambiente via dotenv-rails, inclusive test).
    def stub_mapbox_fetch(result)
      original = MapboxStaticMap.instance_method(:fetch)
      MapboxStaticMap.define_method(:fetch) { result }
      yield
    ensure
      MapboxStaticMap.define_method(:fetch, original)
    end
end
