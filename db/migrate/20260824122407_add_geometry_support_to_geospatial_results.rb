class AddGeometrySupportToGeospatialResults < ActiveRecord::Migration[8.1]
  # KmzGeometryExtractor só lia <Polygon> — KMZ real com <LineString>/<Point> (linha de
  # transmissão, torre de medição eólica) sempre quebrava com NoPolygonFoundError, visto em
  # produção. A coluna "polygon" era geography tipada estritamente como st_polygon — não aceita
  # LineString/MultiPoint. Renomeia pra "geometry" (mais preciso agora) e afrouxa o tipo pra
  # geography genérico (aceita Polygon, LineString ou MultiPoint) — mudança segura pros polígonos
  # já salvos, que continuam válidos sob o tipo mais largo.
  def change
    rename_column :geospatial_results, :polygon, :geometry
    change_column :geospatial_results, :geometry, :geography, limit: { srid: 4326, type: "geometry", geographic: true }

    add_column :geospatial_results, :geometry_type, :string, default: "polygon", null: false
    add_column :geospatial_results, :length_km, :decimal, precision: 14, scale: 4
  end
end
