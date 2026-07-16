class CreateGeospatialResults < ActiveRecord::Migration[8.1]
  def change
    create_table :geospatial_results do |t|
      t.references :conversation, null: false, foreign_key: true, index: { unique: true }
      t.decimal :area_ha, precision: 14, scale: 4
      t.decimal :perimeter_km, precision: 14, scale: 4
      t.st_point :centroid, geographic: true
      t.st_polygon :polygon, geographic: true
      t.jsonb :municipalities, null: false, default: []
      t.boolean :mata_atlantica
      t.boolean :unidade_conservacao
      t.boolean :terra_indigena
      t.boolean :quilombo
      t.string :watershed
      t.string :map_image_url

      t.timestamps
    end
  end
end
