require "test_helper"

class KmzGeometryExtractorTest < ActiveSupport::TestCase
  RECTANGLE_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Poligono Principal</name>
          <Polygon>
            <outerBoundaryIs>
              <LinearRing>
                <coordinates>
                  -40.30,-14.85,0 -40.28,-14.85,0 -40.28,-14.83,0 -40.30,-14.83,0 -40.30,-14.85,0
                </coordinates>
              </LinearRing>
            </outerBoundaryIs>
          </Polygon>
        </Placemark>
      </Document>
    </kml>
  KML

  MULTI_POLYGON_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Area Principal</name>
          <Polygon>
            <outerBoundaryIs>
              <LinearRing>
                <coordinates>-40.30,-14.85,0 -40.28,-14.85,0 -40.28,-14.83,0 -40.30,-14.83,0 -40.30,-14.85,0</coordinates>
              </LinearRing>
            </outerBoundaryIs>
          </Polygon>
        </Placemark>
        <Placemark>
          <name>Acesso</name>
          <Polygon>
            <outerBoundaryIs>
              <LinearRing>
                <coordinates>-40.32,-14.86,0 -40.315,-14.86,0 -40.315,-14.855,0 -40.32,-14.855,0 -40.32,-14.86,0</coordinates>
              </LinearRing>
            </outerBoundaryIs>
          </Polygon>
        </Placemark>
      </Document>
    </kml>
  KML

  # Linha de transmissão real: KMZ com LineString e Point, sem nenhum Polygon — achado em
  # produção, quebrava com NoPolygonFoundError antes desta classe suportar os três tipos.
  LINE_AND_POINTS_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark>
          <name>Linha de Transmissão</name>
          <LineString>
            <coordinates>-40.30,-14.85,0 -40.29,-14.84,0 -40.28,-14.83,0</coordinates>
          </LineString>
        </Placemark>
        <Placemark>
          <name>Torre 1</name>
          <Point><coordinates>-40.30,-14.85,0</coordinates></Point>
        </Placemark>
        <Placemark>
          <name>Torre 2</name>
          <Point><coordinates>-40.28,-14.83,0</coordinates></Point>
        </Placemark>
      </Document>
    </kml>
  KML

  POINTS_ONLY_KML = <<~KML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <Placemark><name>Torre Anemométrica</name><Point><coordinates>-40.29,-14.84,0</coordinates></Point></Placemark>
      </Document>
    </kml>
  KML

  test "computes area and perimeter for a single polygon, matching hand-calculated values" do
    result = KmzGeometryExtractor.new(RECTANGLE_KML).call

    assert_equal "polygon", result.geometry_type
    assert_in_delta 478.07, result.area_ha, 0.5
    assert_in_delta 8.75, result.perimeter_km, 0.05
    assert_in_delta(-40.29, result.centroid.x, 0.01)
    assert_in_delta(-14.84, result.centroid.y, 0.01)
    assert_kind_of RGeo::Feature::Polygon, result.geometry
    assert_equal 1, result.local_rings.size
  end

  test "accepts a KMZ (zipped KML), finding the .kml entry regardless of its name" do
    kmz_bytes = build_kmz("area_de_estudo.kml", RECTANGLE_KML)

    result = KmzGeometryExtractor.new(kmz_bytes).call

    assert_in_delta 478.07, result.area_ha, 0.5
  end

  test "sums areas across multiple polygons and keeps the largest as the stored geometry" do
    result = KmzGeometryExtractor.new(MULTI_POLYGON_KML).call

    assert_equal 2, result.local_rings.size
    assert_in_delta 507.9, result.area_ha, 0.5 # 478.07 (principal) + ~29.86 (acesso)
  end

  test "computes length in km for a LineString, when there is no polygon" do
    result = KmzGeometryExtractor.new(LINE_AND_POINTS_KML).call

    assert_equal "line", result.geometry_type
    assert_nil result.area_ha
    assert_in_delta 2.9, result.length_km, 0.2
    assert_kind_of RGeo::Feature::LineString, result.geometry
    assert_equal 1, result.local_lines.size
  end

  test "also extracts points found alongside a line, even though the geometry_type stays 'line'" do
    result = KmzGeometryExtractor.new(LINE_AND_POINTS_KML).call

    assert_equal 2, result.local_points.size
  end

  test "extracts a single Point when the KMZ has no polygon or line" do
    result = KmzGeometryExtractor.new(POINTS_ONLY_KML).call

    assert_equal "point", result.geometry_type
    assert_nil result.area_ha
    assert_nil result.length_km
    assert_kind_of RGeo::Feature::Point, result.geometry
    assert_equal 1, result.local_points.size
    assert_in_delta(-40.29, result.centroid.x, 0.01)
    assert_in_delta(-14.84, result.centroid.y, 0.01)
  end

  test "builds a MultiPoint geometry when there is more than one Point and no line/polygon" do
    kml = <<~KML
      <?xml version="1.0" encoding="UTF-8"?>
      <kml xmlns="http://www.opengis.net/kml/2.2">
        <Document>
          <Placemark><Point><coordinates>-40.30,-14.85,0</coordinates></Point></Placemark>
          <Placemark><Point><coordinates>-40.28,-14.83,0</coordinates></Point></Placemark>
        </Document>
      </kml>
    KML

    result = KmzGeometryExtractor.new(kml).call

    assert_kind_of RGeo::Feature::MultiPoint, result.geometry
    assert_equal 2, result.local_points.size
  end

  test "raises NoGeometryFoundError for a valid zip that has no .kml entry inside" do
    zip_without_kml = build_kmz("readme.txt", "isso não é um KML")

    assert_raises(KmzGeometryExtractor::NoGeometryFoundError) do
      KmzGeometryExtractor.new(zip_without_kml).call
    end
  end

  test "raises NoGeometryFoundError when the file has no polygon, line or point at all" do
    assert_raises(KmzGeometryExtractor::NoGeometryFoundError) do
      KmzGeometryExtractor.new("isso não é um KMZ nem KML válido").call
    end
  end

  private
    def build_kmz(entry_name, kml_content)
      Tempfile.create([ "test", ".kmz" ], binmode: true) do |tmp|
        Zip::File.open(tmp.path, create: true) do |zip|
          zip.get_output_stream(entry_name) { |f| f.write(kml_content) }
        end
        File.binread(tmp.path)
      end
    end
end
