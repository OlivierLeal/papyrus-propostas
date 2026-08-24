require "test_helper"

class MapboxStaticMapTest < ActiveSupport::TestCase
  POLYGON = KmzGeometryExtractor::FACTORY.polygon(
    KmzGeometryExtractor::FACTORY.linear_ring(
      [ [ -40.30, -14.85 ], [ -40.28, -14.85 ], [ -40.28, -14.83 ], [ -40.30, -14.83 ], [ -40.30, -14.85 ] ]
        .map { |lon, lat| KmzGeometryExtractor::FACTORY.point(lon, lat) }
    )
  )

  LINE_STRING = KmzGeometryExtractor::FACTORY.line_string(
    [ [ -40.30, -14.85 ], [ -40.29, -14.84 ], [ -40.28, -14.83 ] ]
      .map { |lon, lat| KmzGeometryExtractor::FACTORY.point(lon, lat) }
  )

  POINT = KmzGeometryExtractor::FACTORY.point(-40.29, -14.84)

  test "available? reflects whether MAPBOX_API_KEY is set" do
    with_env("MAPBOX_API_KEY", "token123") { assert MapboxStaticMap.available? }
    with_env("MAPBOX_API_KEY", nil) { assert_not MapboxStaticMap.available? }
  end

  test "fetch returns nil without raising when there is no API key configured" do
    with_env("MAPBOX_API_KEY", nil) do
      assert_nil MapboxStaticMap.new(POLYGON).fetch
    end
  end

  test "fetch builds the request URL with style, token and the polygon as a GeoJSON overlay, and returns the body on success" do
    captured_uri = nil
    fake_response = fake_success_response("fake-png-bytes")
    original = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response) do |uri, *|
      captured_uri = uri
      fake_response
    end

    body = with_env("MAPBOX_API_KEY", "token123") { MapboxStaticMap.new(POLYGON).fetch }
    assert_equal "fake-png-bytes", body

    assert_includes captured_uri.to_s, "https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/static/"
    assert_includes captured_uri.to_s, "access_token=token123"
    assert_includes captured_uri.to_s, "/auto/800x600.png"

    decoded = CGI.unescape(captured_uri.to_s[/geojson\((.+?)\)\/auto/, 1])
    geojson = JSON.parse(decoded)
    assert_equal "Polygon", geojson.dig("geometry", "type")
    assert_equal 5, geojson.dig("geometry", "coordinates", 0).size
    assert_equal "#0ea5e9", geojson.dig("properties", "fill")
  ensure
    Net::HTTP.define_singleton_method(:get_response, original)
  end

  # Achado num KMZ real em produção: linha de transmissão (LineString) e ponto de medição, sem
  # nenhum polígono — MapboxStaticMap assumia Polygon sempre e quebraria (undefined method
  # `exterior_ring' for a LineString).
  test "fetch builds a LineString overlay (stroke only, no fill) when the geometry is a line" do
    captured_uri = build_geojson_for(LINE_STRING)

    assert_equal "LineString", captured_uri.dig("geometry", "type")
    assert_equal 3, captured_uri.dig("geometry", "coordinates").size
    assert_equal "#0284c7", captured_uri.dig("properties", "stroke")
    assert_nil captured_uri.dig("properties", "fill")
  end

  test "fetch builds a Point overlay (marker, no stroke/fill) when the geometry is a point" do
    captured_uri = build_geojson_for(POINT)

    assert_equal "Point", captured_uri.dig("geometry", "type")
    assert_equal [ -40.29, -14.84 ], captured_uri.dig("geometry", "coordinates")
    assert_equal "#0284c7", captured_uri.dig("properties", "marker-color")
  end

  test "fetch returns nil without raising when the response isn't a success" do
    original = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response) { |*| Net::HTTPNotFound.new("1.1", "404", "Not Found") }

    with_env("MAPBOX_API_KEY", "token123") do
      assert_nil MapboxStaticMap.new(POLYGON).fetch
    end
  ensure
    Net::HTTP.define_singleton_method(:get_response, original)
  end

  test "fetch returns nil without raising when the request itself errors out" do
    original = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response) { |*| raise SocketError, "falha de rede" }

    with_env("MAPBOX_API_KEY", "token123") do
      assert_nil MapboxStaticMap.new(POLYGON).fetch
    end
  ensure
    Net::HTTP.define_singleton_method(:get_response, original)
  end

  private
    def build_geojson_for(geometry)
      fake_response = fake_success_response("bytes")
      captured_uri = nil
      original = Net::HTTP.method(:get_response)
      Net::HTTP.define_singleton_method(:get_response) do |uri, *|
        captured_uri = uri
        fake_response
      end

      with_env("MAPBOX_API_KEY", "token123") { MapboxStaticMap.new(geometry).fetch }
      decoded = CGI.unescape(captured_uri.to_s[/geojson\((.+?)\)\/auto/, 1])
      JSON.parse(decoded)
    ensure
      Net::HTTP.define_singleton_method(:get_response, original)
    end

    def fake_success_response(body)
      Net::HTTPOK.new("1.1", "200", "OK").tap { |response| response.define_singleton_method(:body) { body } }
    end

    def with_env(key, value)
      original = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
      yield
    ensure
      original.nil? ? ENV.delete(key) : ENV[key] = original
    end
end
