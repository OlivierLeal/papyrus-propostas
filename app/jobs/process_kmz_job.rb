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
    geospatial_result.sketch_image.attach(
      io: StringIO.new(PolygonSketchRenderer.new(result.local_rings).call),
      filename: "croqui.svg", content_type: "image/svg+xml"
    )

    conversation.mark_step!("kmz", "done")
  rescue StandardError => e
    Rails.logger.error("ProcessKmzJob failed for conversation #{conversation_id}: #{e.class} #{e.message}")
    conversation&.mark_step!("kmz", "failed")
  ensure
    conversation&.check_processing_complete!
  end
end
