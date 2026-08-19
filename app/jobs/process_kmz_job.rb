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
      area_ha: result.area_ha, perimeter_km: result.perimeter_km, centroid: result.centroid, polygon: result.polygon
    )
    attach_area_image!(geospatial_result, result)

    conversation.mark_step!("kmz", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessKmzJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("kmz", "failed")
  ensure
    conversation&.check_processing_complete!
  end

  private
    # Mapa real (satélite + polígono, via Mapbox) quando disponível; croqui SVG local como
    # reserva automática se a chave não estiver configurada ou a chamada falhar por qualquer motivo.
    def attach_area_image!(geospatial_result, result)
      image_bytes = MapboxStaticMap.new(result.polygon).fetch
      if image_bytes
        geospatial_result.area_image.attach(
          io: StringIO.new(image_bytes), filename: "mapa.png", content_type: "image/png"
        )
      else
        geospatial_result.area_image.attach(
          io: StringIO.new(PolygonSketchRenderer.new(result.local_rings).call),
          filename: "croqui.svg", content_type: "image/svg+xml"
        )
      end
    end
end
