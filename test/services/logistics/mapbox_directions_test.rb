require "test_helper"

class Logistics::MapboxDirectionsTest < ActiveSupport::TestCase
  ORIGIN = KmzGeometryExtractor::FACTORY.point(-38.325, -12.897)
  DESTINATION = KmzGeometryExtractor::FACTORY.point(-39.5, -14.0)

  test "available? reflects whether MAPBOX_API_KEY is set" do
    with_env("MAPBOX_API_KEY", "token123") { assert Logistics::MapboxDirections.available? }
    with_env("MAPBOX_API_KEY", nil) { assert_not Logistics::MapboxDirections.available? }
  end

  test "fetch returns nil without raising when there is no API key configured" do
    with_env("MAPBOX_API_KEY", nil) do
      assert_nil Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch
    end
  end

  test "fetch parses distance (km) and duration (hours) from the fastest route on success" do
    body = { routes: [ { distance: 250_000, duration: 10_800 } ] }.to_json
    stub_get_response(fake_success_response(body)) do
      result = with_env("MAPBOX_API_KEY", "token123") { Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch }

      assert_equal 250.0, result.distance_km
      assert_equal 3.0, result.duration_hours
    end
  end

  test "fetch includes both coordinates and the token in the request URL" do
    body = { routes: [ { distance: 1000, duration: 60 } ] }.to_json
    captured_uri = nil
    stub_get_response(fake_success_response(body), capture: ->(uri) { captured_uri = uri }) do
      with_env("MAPBOX_API_KEY", "token123") { Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch }
    end

    assert_includes captured_uri.to_s, "https://api.mapbox.com/directions/v5/mapbox/driving/"
    assert_includes captured_uri.to_s, "-38.325,-12.897;-39.5,-14.0"
    assert_includes captured_uri.to_s, "access_token=token123"
  end

  test "fetch returns nil without raising when there is no route in the response" do
    body = { routes: [] }.to_json
    stub_get_response(fake_success_response(body)) do
      assert_nil with_env("MAPBOX_API_KEY", "token123") { Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch }
    end
  end

  test "fetch returns nil without raising when the response isn't a success" do
    stub_get_response(Net::HTTPNotFound.new("1.1", "404", "Not Found")) do
      assert_nil with_env("MAPBOX_API_KEY", "token123") { Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch }
    end
  end

  test "fetch returns nil without raising when the request itself errors out" do
    original = Net::HTTP.method(:get_response)
    Net::HTTP.define_singleton_method(:get_response) { |*| raise SocketError, "falha de rede" }

    with_env("MAPBOX_API_KEY", "token123") do
      assert_nil Logistics::MapboxDirections.new(ORIGIN, DESTINATION).fetch
    end
  ensure
    Net::HTTP.define_singleton_method(:get_response, original)
  end

  private
    def stub_get_response(response, capture: nil)
      original = Net::HTTP.method(:get_response)
      Net::HTTP.define_singleton_method(:get_response) do |uri, *|
        capture&.call(uri)
        response
      end
      yield
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
