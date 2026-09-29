require "test_helper"

class Lodging::Stay22ClientTest < ActiveSupport::TestCase
  # Formato real da resposta (api.stay22.com/v2/accommodations, conferido em 2026-09-29).
  test "parses the cheapest supplier price per night and the city from the address" do
    body = {
      "meta" => { "nights" => 3, "currency" => "BRL" },
      "results" => [
        { "id" => "x1", "name" => "Pousada Rebeca", "type" => "Accommodation", "url" => "https://www.stay22.com/allez/x1",
          "suppliers" => { "booking" => { "price" => { "total" => 360 } }, "expedia" => { "price" => { "total" => 330 } } },
          "location" => { "address" => "Rua A, 10, Irecê Brazil, 44900-000", "coordinates" => { "lat" => -11.3, "lng" => -41.85 } } },
        { "id" => "x2", "name" => "Sem preço", "suppliers" => {}, "location" => { "coordinates" => { "lat" => 1, "lng" => 1 } } }
      ]
    }

    options = Lodging::Stay22Client.new.send(:parse, body)

    assert_equal 1, options.size
    assert_equal 110, options.first.price_per_night
    assert_equal "Irecê", options.first.city
  end
end
