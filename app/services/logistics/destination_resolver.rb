# Ponto de destino (RGeo, .x=lon/.y=lat) pra calcular distância/logística — usado por
# ProjectPricing#suggest_logistics!. Só usa fontes ESTRUTURADAS de município (sempre com UF em
# sigla, sem ambiguidade) — nunca o texto livre de ProjectFinding#value pro campo "municipios",
# que quando vem do ET/TR (IA) não garante UF (achado na exploração: município do mesmo nome
# existe em vários estados, geocodificar errado silenciosamente entraria no preço).
module Logistics
  class DestinationResolver
    # Sede da Papyrus (Lauro de Freitas/BA) — centro aproximado do município, não o endereço
    # exato do escritório (suficiente pra estimativa de logística, sempre editável depois).
    # Ajustar aqui se um dia quiser o endereço exato.
    PAPYRUS_HQ_POINT = KmzGeometryExtractor::FACTORY.point(-38.325, -12.897)

    def self.call(proposal)
      geospatial = proposal.conversation.geospatial_result
      return nil unless geospatial

      geospatial.centroid || municipality_centroid(geospatial)
    end

    def self.municipality_centroid(geospatial)
      first = geospatial.municipalities.first
      return nil unless first

      IbgeMunicipality.find_by(code_ibge: first["code_ibge"])&.centroid
    end
  end
end
