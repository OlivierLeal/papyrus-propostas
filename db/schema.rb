# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_31_144818) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "postgis"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "conversations", force: :cascade do |t|
    t.string "client_name", null: false
    t.datetime "created_at", null: false
    t.bigint "model_id"
    t.jsonb "processing_steps", default: {}, null: false
    t.datetime "setup_completed_at"
    t.string "status", default: "setup", null: false
    t.bigint "study_type_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["model_id"], name: "index_conversations_on_model_id"
    t.index ["status"], name: "index_conversations_on_status"
    t.index ["study_type_id"], name: "index_conversations_on_study_type_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "geospatial_results", force: :cascade do |t|
    t.decimal "area_ha", precision: 14, scale: 4
    t.geography "centroid", limit: {:srid=>4326, :type=>"st_point", :geographic=>true}
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.geography "geometry", limit: {:srid=>4326, :type=>"geometry", :geographic=>true}
    t.string "geometry_type", default: "polygon", null: false
    t.decimal "length_km", precision: 14, scale: 4
    t.string "map_image_url"
    t.boolean "mata_atlantica"
    t.jsonb "municipalities", default: [], null: false
    t.decimal "perimeter_km", precision: 14, scale: 4
    t.boolean "quilombo"
    t.boolean "terra_indigena"
    t.boolean "unidade_conservacao"
    t.datetime "updated_at", null: false
    t.string "watershed"
    t.index ["conversation_id"], name: "index_geospatial_results_on_conversation_id", unique: true
  end

  create_table "historical_proposal_chunks", force: :cascade do |t|
    t.boolean "boilerplate", default: false, null: false
    t.boolean "contains_pricing", default: false, null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_model"
    t.bigint "historical_proposal_id", null: false
    t.integer "position", null: false
    t.string "section_number"
    t.string "section_title"
    t.boolean "sensitive", default: false, null: false
    t.string "sensitivity_reasons", default: [], array: true
    t.integer "token_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["boilerplate"], name: "index_historical_proposal_chunks_on_boilerplate"
    t.index ["embedding"], name: "index_hp_chunks_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["historical_proposal_id", "position"], name: "index_hp_chunks_on_proposal_and_position", unique: true
  end

  create_table "historical_proposals", force: :cascade do |t|
    t.string "chunker_version", null: false
    t.string "client_name"
    t.bigint "conversation_id"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "filename", null: false
    t.string "job_name", null: false
    t.string "job_number"
    t.string "origin", default: "acervo", null: false
    t.integer "page_count", default: 0, null: false
    t.jsonb "pricing_data"
    t.string "relative_path", null: false
    t.integer "revision"
    t.string "role", null: false
    t.string "role_source", null: false
    t.string "source_path", null: false
    t.string "source_sha256", null: false
    t.string "spreadsheet_path"
    t.string "status", null: false
    t.string "subject"
    t.boolean "superseded", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "year"
    t.index ["conversation_id"], name: "index_historical_proposals_on_conversation_id"
    t.index ["job_number"], name: "index_historical_proposals_on_job_number"
    t.index ["origin"], name: "index_historical_proposals_on_origin"
    t.index ["role", "superseded"], name: "index_historical_proposals_on_role_and_superseded"
    t.index ["source_sha256"], name: "index_historical_proposals_on_source_sha256", unique: true
  end

  create_table "knowledge_notes", force: :cascade do |t|
    t.datetime "approved_at"
    t.bigint "approved_by_id"
    t.string "category", null: false
    t.string "client_name"
    t.text "content", null: false
    t.text "context"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.datetime "embedded_at"
    t.vector "embedding", limit: 1024
    t.string "embedding_model"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_by_id"], name: "index_knowledge_notes_on_approved_by_id"
    t.index ["category"], name: "index_knowledge_notes_on_category"
    t.index ["conversation_id"], name: "index_knowledge_notes_on_conversation_id"
    t.index ["embedding"], name: "index_knowledge_notes_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["status", "client_name"], name: "index_knowledge_notes_on_status_and_client_name"
  end

  create_table "logistics_configs", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.decimal "fuel_price_per_liter", precision: 10, scale: 2, null: false
    t.decimal "lodging_per_day", precision: 10, scale: 2, null: false
    t.decimal "meal_per_day", precision: 10, scale: 2, null: false
    t.string "name", null: false
    t.decimal "rental_per_day", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_logistics_configs_on_active"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "cache_creation_tokens"
    t.integer "cached_tokens"
    t.text "content"
    t.json "content_raw"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "input_tokens"
    t.boolean "internal", default: false, null: false
    t.bigint "model_id"
    t.integer "output_tokens"
    t.string "role", null: false
    t.text "thinking_signature"
    t.text "thinking_text"
    t.integer "thinking_tokens"
    t.bigint "tool_call_id"
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["model_id"], name: "index_messages_on_model_id"
    t.index ["role"], name: "index_messages_on_role"
    t.index ["tool_call_id"], name: "index_messages_on_tool_call_id"
  end

  create_table "models", force: :cascade do |t|
    t.json "capabilities", default: []
    t.integer "context_window"
    t.datetime "created_at", null: false
    t.string "family"
    t.date "knowledge_cutoff"
    t.integer "max_output_tokens"
    t.json "metadata", default: {}
    t.json "modalities", default: {}
    t.datetime "model_created_at"
    t.string "model_id", null: false
    t.string "name", null: false
    t.json "pricing", default: {}
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["family"], name: "index_models_on_family"
    t.index ["provider", "model_id"], name: "index_models_on_provider_and_model_id", unique: true
    t.index ["provider"], name: "index_models_on_provider"
  end

  create_table "professionals", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.boolean "always_included", default: false, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.decimal "rate_field", precision: 10, scale: 2, null: false
    t.decimal "rate_office", precision: 10, scale: 2, null: false
    t.string "registration"
    t.string "role", null: false
    t.string "specialties"
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_professionals_on_active"
  end

  create_table "project_conflict_findings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "project_conflict_id", null: false
    t.bigint "project_finding_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_conflict_id", "project_finding_id"], name: "index_conflict_findings_uniqueness", unique: true
    t.index ["project_conflict_id"], name: "index_project_conflict_findings_on_project_conflict_id"
    t.index ["project_finding_id"], name: "index_project_conflict_findings_on_project_finding_id"
  end

  create_table "project_conflicts", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "field", null: false
    t.text "resolution_note"
    t.datetime "resolved_at"
    t.bigint "resolved_by_id"
    t.string "status", default: "open", null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "status"], name: "index_project_conflicts_on_conversation_id_and_status"
    t.index ["conversation_id"], name: "index_project_conflicts_on_conversation_id"
    t.index ["resolved_by_id"], name: "index_project_conflicts_on_resolved_by_id"
  end

  create_table "project_findings", force: :cascade do |t|
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.text "excerpt"
    t.string "field", null: false
    t.string "locator"
    t.string "nature", default: "fato", null: false
    t.bigint "source_blob_id"
    t.string "source_kind", null: false
    t.string "status", default: "active", null: false
    t.bigint "superseded_by_id"
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["conversation_id", "field", "status"], name: "index_project_findings_on_conversation_id_and_field_and_status"
    t.index ["conversation_id"], name: "index_project_findings_on_conversation_id"
    t.index ["source_blob_id"], name: "index_project_findings_on_source_blob_id"
    t.index ["superseded_by_id"], name: "index_project_findings_on_superseded_by_id"
  end

  create_table "project_pricings", force: :cascade do |t|
    t.decimal "bdi", precision: 6, scale: 4, default: "1.2", null: false
    t.datetime "created_at", null: false
    t.decimal "distance_km", precision: 10, scale: 2, default: "0.0", null: false
    t.jsonb "external_costs", default: [], null: false
    t.decimal "fuel_total", precision: 10, scale: 2, default: "0.0", null: false
    t.integer "logistics_days", default: 0, null: false
    t.decimal "meal_per_day", precision: 10, scale: 2, default: "0.0", null: false
    t.jsonb "payment_schedule", default: [{"label"=>"Assinatura do contrato", "percentage"=>30}, {"label"=>"Protocolo no órgão ambiental", "percentage"=>60}, {"label"=>"Vistoria", "percentage"=>5}, {"label"=>"Emissão da licença", "percentage"=>5}], null: false
    t.bigint "proposal_id", null: false
    t.decimal "rental_per_day", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "tax_multiplier", precision: 6, scale: 4, default: "1.25", null: false
    t.decimal "total_value", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["proposal_id"], name: "index_project_pricings_on_proposal_id", unique: true
  end

  create_table "proposal_professionals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "deliverable_name", null: false
    t.decimal "hours_field", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "hours_office", precision: 8, scale: 2, default: "0.0", null: false
    t.bigint "professional_id", null: false
    t.bigint "project_pricing_id", null: false
    t.decimal "subtotal", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["professional_id"], name: "index_proposal_professionals_on_professional_id"
    t.index ["project_pricing_id"], name: "index_proposal_professionals_on_project_pricing_id"
  end

  create_table "proposals", force: :cascade do |t|
    t.jsonb "content_json", default: {}, null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "document_split", default: "combined", null: false
    t.string "docx_filename_override"
    t.string "pdf_url"
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 0, null: false
    t.index ["conversation_id"], name: "index_proposals_on_conversation_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "study_templates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "deliverable_name", null: false
    t.decimal "hours_field_default", precision: 8, scale: 2, default: "0.0", null: false
    t.decimal "hours_office_default", precision: 8, scale: 2, default: "0.0", null: false
    t.bigint "professional_id", null: false
    t.bigint "study_type_id", null: false
    t.datetime "updated_at", null: false
    t.index ["professional_id"], name: "index_study_templates_on_professional_id"
    t.index ["study_type_id", "professional_id", "deliverable_name"], name: "index_study_templates_on_type_professional_deliverable", unique: true
    t.index ["study_type_id"], name: "index_study_templates_on_study_type_id"
  end

  create_table "study_types", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_study_types_on_code", unique: true
  end

  create_table "tool_calls", force: :cascade do |t|
    t.json "arguments", default: {}
    t.datetime "created_at", null: false
    t.bigint "message_id", null: false
    t.string "name", null: false
    t.text "thought_signature"
    t.string "tool_call_id", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_calls_on_message_id"
    t.index ["name"], name: "index_tool_calls_on_name"
    t.index ["tool_call_id"], name: "index_tool_calls_on_tool_call_id", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "conversations", "models"
  add_foreign_key "conversations", "study_types"
  add_foreign_key "conversations", "users"
  add_foreign_key "geospatial_results", "conversations"
  add_foreign_key "historical_proposal_chunks", "historical_proposals"
  add_foreign_key "historical_proposals", "conversations"
  add_foreign_key "knowledge_notes", "conversations"
  add_foreign_key "knowledge_notes", "users", column: "approved_by_id"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "models"
  add_foreign_key "messages", "tool_calls"
  add_foreign_key "project_conflict_findings", "project_conflicts"
  add_foreign_key "project_conflict_findings", "project_findings"
  add_foreign_key "project_conflicts", "conversations"
  add_foreign_key "project_conflicts", "users", column: "resolved_by_id"
  add_foreign_key "project_findings", "active_storage_blobs", column: "source_blob_id"
  add_foreign_key "project_findings", "conversations"
  add_foreign_key "project_findings", "project_findings", column: "superseded_by_id"
  add_foreign_key "project_pricings", "proposals"
  add_foreign_key "proposal_professionals", "professionals"
  add_foreign_key "proposal_professionals", "project_pricings"
  add_foreign_key "proposals", "conversations"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "study_templates", "professionals"
  add_foreign_key "study_templates", "study_types"
  add_foreign_key "tool_calls", "messages"
end
