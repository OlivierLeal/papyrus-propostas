# Ponto de destino (RGeo, .x=lon/.y=lat) pra calcular distância/logística — usado por
# ProjectPricing#suggest_logistics!, FieldCampaign#area_point e Lodging::Search. Fontes, nesta
# ordem de autoridade:
#   1. local do projeto informado pelo consultor (Tela de Precificação ou chat — SetProjectLocationTool);
#   2. centroide do KMZ;
#   3. primeiro município cruzado pelo ProcessKmzJob (sempre com UF);
#   4. (2026-09-29, proposta sem KMZ) município citado nos achados "municipios" — ET, TR, chat —,
#      do mais autoritativo pro menos. Só entra quando IbgeMunicipality.lookup resolve SEM
#      ambiguidade (texto com UF, ou nome único no país): município do mesmo nome existe em vários
#      estados, e geocodificar errado em silêncio entraria no preço.
module Logistics
  class DestinationResolver
    # Sede da Papyrus (Lauro de Freitas/BA) — centro aproximado do município, não o endereço
    # exato do escritório (suficiente pra estimativa de logística, sempre editável depois).
    # Ajustar aqui se um dia quiser o endereço exato.
    PAPYRUS_HQ_POINT = KmzGeometryExtractor::FACTORY.point(-38.325, -12.897)

    Destination = Data.define(:point, :label, :source)

    def self.call(proposal)
      resolve(proposal)&.point
    end

    def self.resolve(proposal)
      from_pricing(proposal.project_pricing) || for_conversation(proposal.conversation)
    end

    # Antes de a proposta existir (snapshot da IA): só KMZ e achados.
    def self.for_conversation(conversation)
      from_kmz(conversation) || from_findings(conversation)
    end

    def self.from_pricing(pricing)
      municipality = pricing&.ibge_municipality
      point = municipality&.centroid
      Destination.new(point: point, label: municipality.label, source: "informado pelo consultor") if point
    end

    def self.from_kmz(conversation)
      geospatial = conversation.geospatial_result
      return nil unless geospatial

      if (centroid = geospatial.centroid)
        return Destination.new(point: centroid, label: geospatial.municipalities_label.presence || "área do KMZ", source: "KMZ")
      end

      first = geospatial.municipalities.first
      municipality = first && IbgeMunicipality.find_by(code_ibge: first["code_ibge"])
      point = municipality&.centroid
      Destination.new(point: point, label: municipality.label, source: "município do KMZ") if point
    end

    def self.from_findings(conversation)
      authority = ProjectFinding::SOURCE_KINDS.keys
      findings = conversation.project_findings.active.where(field: "municipios").to_a
        .sort_by { |finding| [ authority.index(finding.source_kind) || authority.size, recency_key(finding) ] }
      findings.each do |finding|
        municipality = IbgeMunicipality.lookup(finding.value)
        point = municipality&.centroid
        return Destination.new(point: point, label: municipality.label, source: finding.source_label) if point
      end
      nil
    end

    # O consultor corrige: vale o que ele disse por último. Documento lista: o primeiro município
    # citado costuma ser o principal (projeto que cruza vários).
    def self.recency_key(finding)
      finding.source_kind == "consultor" ? -finding.created_at.to_f : finding.id
    end
  end
end
