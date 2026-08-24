class ProcessKmzJob < ApplicationJob
  queue_as :default

  # Só geometria do próprio polígono (área/perímetro/centroide + croqui) — nenhuma camada de
  # referência (municípios/biomas/UCs) é processada aqui, ver CLAUDE.md seção 11.1. Determinístico,
  # sem chamada de IA.
  def perform(conversation_id)
    conversation = Conversation.find(conversation_id)
    attachment = conversation.attachment_of_kind("kmz")
    return conversation.mark_step!("kmz", "skipped") unless attachment

    conversation.mark_step!("kmz", "running")
    result = KmzGeometryExtractor.new(attachment.blob.download).call

    geospatial_result = conversation.create_geospatial_result!(
      geometry_type: result.geometry_type, area_ha: result.area_ha, perimeter_km: result.perimeter_km,
      length_km: result.length_km, centroid: result.centroid, geometry: result.geometry
    )
    attach_area_image!(geospatial_result, result)
    record_findings!(conversation, attachment, result)

    conversation.mark_step!("kmz", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessKmzJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("kmz", "failed")
  ensure
    conversation&.check_processing_complete!
  end

  private
    # Área e perímetro medidos entram como achado igual a qualquer outro — com source_kind
    # "sistema", que é a fonte mais forte depois da decisão do consultor (ver ProjectFinding).
    # É o que permite o sistema perceber sozinho que o TR declara uma área e o polígono mede
    # outra: sem isso, a medição ficava só no resumo e ninguém comparava com o documento.
    def record_findings!(conversation, attachment, result)
      { "area_ha" => result.area_ha, "perimetro_km" => result.perimeter_km }.each do |field, value|
        next if value.blank? || value.to_f.zero?

        conversation.project_findings.create!(
          field: field, value: value.to_f.round(2).to_s, nature: "fato", source_kind: "sistema",
          source_blob: attachment.blob,
          excerpt: "Medido pelo sistema a partir da geometria do KMZ (#{attachment.filename})."
        )
      end
    end

    # Mapa real (satélite + geometria, via Mapbox) quando disponível; croqui SVG local como
    # reserva automática se a chave não estiver configurada ou a chamada falhar por qualquer motivo.
    def attach_area_image!(geospatial_result, result)
      image_bytes = MapboxStaticMap.new(result.geometry).fetch
      if image_bytes
        geospatial_result.area_image.attach(
          io: StringIO.new(image_bytes), filename: "mapa.png", content_type: "image/png"
        )
      else
        svg = AreaSketchRenderer.new(
          local_rings: result.local_rings, local_lines: result.local_lines, local_points: result.local_points
        ).call
        geospatial_result.area_image.attach(
          io: StringIO.new(svg), filename: "croqui.svg", content_type: "image/svg+xml"
        )
      end
    end
end
