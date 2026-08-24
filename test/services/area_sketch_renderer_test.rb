require "test_helper"

class AreaSketchRendererTest < ActiveSupport::TestCase
  test "renders a valid SVG with one <polygon> per ring, points inside the viewBox" do
    rings = [ [ [ 0, 0 ], [ 100, 0 ], [ 100, 50 ], [ 0, 50 ], [ 0, 0 ] ] ]

    svg = AreaSketchRenderer.new(local_rings: rings).call

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

    svg = AreaSketchRenderer.new(local_rings: rings).call

    assert_equal 2, svg.scan("<polygon").size
  end

  test "does not blow up on a degenerate ring where every point is the same (zero span)" do
    rings = [ [ [ 5, 5 ], [ 5, 5 ], [ 5, 5 ] ] ]

    svg = AreaSketchRenderer.new(local_rings: rings).call

    assert_includes svg, "<polygon"
  end

  # Achado num KMZ real em produção: linha de transmissão (LineString) sem nenhum polígono —
  # KmzGeometryExtractor quebrava (NoPolygonFoundError); agora vira croqui de linha.
  test "renders one <polyline> per line, without any <polygon>" do
    lines = [ [ [ 0, 0 ], [ 50, 20 ], [ 100, 0 ] ] ]

    svg = AreaSketchRenderer.new(local_lines: lines).call

    assert_equal 1, svg.scan("<polyline").size
    assert_equal 0, svg.scan("<polygon").size
  end

  test "renders one <circle> per point, without any <polygon> or <polyline>" do
    points = [ [ 0, 0 ], [ 30, 30 ] ]

    svg = AreaSketchRenderer.new(local_points: points).call

    assert_equal 2, svg.scan("<circle").size
    assert_equal 0, svg.scan("<polygon").size
    assert_equal 0, svg.scan("<polyline").size
  end

  test "renders rings, lines and points together, all inside the viewBox, when a KMZ mixes shapes" do
    rings = [ [ [ 0, 0 ], [ 40, 0 ], [ 40, 40 ], [ 0, 40 ], [ 0, 0 ] ] ]
    lines = [ [ [ 40, 40 ], [ 80, 60 ] ] ]
    points = [ [ 80, 60 ], [ 90, 70 ] ]

    svg = AreaSketchRenderer.new(local_rings: rings, local_lines: lines, local_points: points).call

    assert_equal 1, svg.scan("<polygon").size
    assert_equal 1, svg.scan("<polyline").size
    assert_equal 2, svg.scan("<circle").size
  end
end
