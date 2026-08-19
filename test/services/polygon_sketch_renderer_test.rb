require "test_helper"

class PolygonSketchRendererTest < ActiveSupport::TestCase
  test "renders a valid SVG with one <polygon> per ring, points inside the viewBox" do
    rings = [ [ [ 0, 0 ], [ 100, 0 ], [ 100, 50 ], [ 0, 50 ], [ 0, 0 ] ] ]

    svg = PolygonSketchRenderer.new(rings).call

    assert_includes svg, "<svg"
    assert_includes svg, 'viewBox="0 0 600 600"'
    assert_equal 1, svg.scan("<polygon").size

    points = svg[/<polygon points="([^"]+)"/, 1].split(" ").map { |p| p.split(",").map(&:to_f) }
    points.each do |x, y|
      assert x.between?(0, 600), "x #{x} fora do viewBox"
      assert y.between?(0, 600), "y #{y} fora do viewBox"
    end
  end

  test "renders one <polygon> tag per ring when there are multiple" do
    rings = [
      [ [ 0, 0 ], [ 10, 0 ], [ 10, 10 ], [ 0, 10 ], [ 0, 0 ] ],
      [ [ 50, 50 ], [ 60, 50 ], [ 60, 60 ], [ 50, 60 ], [ 50, 50 ] ]
    ]

    svg = PolygonSketchRenderer.new(rings).call

    assert_equal 2, svg.scan("<polygon").size
  end

  test "does not blow up on a degenerate ring where every point is the same (zero span)" do
    rings = [ [ [ 5, 5 ], [ 5, 5 ], [ 5, 5 ] ] ]

    svg = PolygonSketchRenderer.new(rings).call

    assert_includes svg, "<polygon"
  end
end
