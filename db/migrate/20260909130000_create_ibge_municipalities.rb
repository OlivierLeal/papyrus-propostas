class CreateIbgeMunicipalities < ActiveRecord::Migration[8.1]
  # Camada de referência do CLAUDE.md seção 3 ("importadas via shapefile para PostGIS") —
  # única das 6 planejadas construída até agora (as outras: Mata Atlântica, UCs, TIs, quilombos,
  # bacias, continuam fora de escopo). Populada por script/geospatial/import_ibge_municipalities.rb
  # a partir da malha oficial do IBGE, não por seed manual.
  #
  # `code_ibge` é o código de 7 dígitos do IBGE (município + UF embutidos nele) — chave natural
  # pra upsert idempotente. `geom` é geography (não geometry) pra bater com
  # geospatial_results.geometry (também geography) e permitir ST_Intersects entre as duas colunas
  # sem cast explícito — mesmo princípio de "mesmo tipo evita fricção" já usado lá.
  def change
    create_table :ibge_municipalities do |t|
      t.string :code_ibge, null: false
      t.string :name, null: false
      t.string :uf, null: false, limit: 2
      t.multi_polygon :geom, geographic: true, srid: 4326, null: false

      t.timestamps
    end

    add_index :ibge_municipalities, :code_ibge, unique: true
    add_index :ibge_municipalities, :geom, using: :gist
  end
end
