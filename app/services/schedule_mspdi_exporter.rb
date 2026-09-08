# Exporta um cronograma (ScheduleItem, CLAUDE.md seção 8) em MSPDI — o XML de intercâmbio do
# MS Project, que ele abre nativamente (Arquivo > Abrir) e importa como projeto completo (fases,
# atividades, datas, marcos). Não é o binário .mpp de verdade — gravar esse formato não é viável
# (nunca foi documentado pra escrita pela Microsoft, só engenharia reversa parcial pra leitura);
# MSPDI é o caminho padrão de qualquer integração séria (é o que a própria MPXJ, biblioteca de
# referência do setor, oferece como writer).
#
# Delega a montagem do org.mpxj.ProjectFile e a gravação pra um helper Java próprio
# (lib/java/ScheduleToMspdi.java, compilado por bin/build_java_helpers) — a gem `mpxj` só tem API
# de LEITURA em Ruby (MPXJ::Reader); escrita usa os mesmos .jar que ela já vendoriza, só que
# chamados direto.
#
# `items` tem que vir na ORDEM de exibição (por `position`, ver ScheduleItem.for_type) — o
# agrupamento por fase é feito detectando troca de `phase_name` entre itens CONSECUTIVOS, mesma
# convenção do ScheduleTableBuilder (que gera a tabela equivalente dentro do .docx). Datas em dias
# corridos (sem calendário de dias úteis) — mesma convenção de lá, nenhuma conta de dia útil entra
# aqui.
require "open3"

class ScheduleMspdiExporter
  class JavaHelperError < StandardError; end

  # unit: :week (cronograma do serviço) ou :month (cronograma de implantação do empreendimento) —
  # mesmo parâmetro do ScheduleTableBuilder.
  def initialize(items:, start_date:, unit:, name:)
    @items = items
    @start_date = start_date
    @unit = unit
    @name = name
  end

  def call
    return nil if @items.blank?

    Tempfile.create([ "schedule", ".json" ]) do |input|
      input.write(build_payload.to_json)
      input.flush

      Tempfile.create([ "schedule", ".xml" ]) do |output|
        run_java!(input.path, output.path)
        return File.binread(output.path)
      end
    end
  end

  private
    def build_payload
      { name: @name, start_date: @start_date.iso8601, tasks: build_tasks }
    end

    def build_tasks
      tasks = []
      next_id = 1

      phase_groups.each do |phase_name, phase_items|
        phase_id = next_id
        next_id += 1

        activity_rows = phase_items.map do |item|
          id = next_id
          next_id += 1
          { id: id, item: item, start: item_start(item), finish: item_finish(item) }
        end

        tasks << task_payload(
          id: phase_id, parent_id: nil, name: phase_name,
          start: activity_rows.map { |r| r[:start] }.min, finish: activity_rows.map { |r| r[:finish] }.max,
          milestone: false
        )
        activity_rows.each do |row|
          tasks << task_payload(
            id: row[:id], parent_id: phase_id, name: row[:item].activity_name,
            start: row[:start], finish: row[:finish], milestone: row[:item].milestone?
          )
        end
      end

      tasks
    end

    # Agrupa itens consecutivos pelo mesmo phase_name — mesma detecção do
    # ScheduleTableBuilder#data_rows_xml, nunca um campo próprio de "é fase".
    def phase_groups
      groups = []
      @items.each do |item|
        groups << [ item.phase_name, [] ] if groups.empty? || groups.last[0] != item.phase_name
        groups.last[1] << item
      end
      groups
    end

    def item_start(item)
      case @unit
      when :week then @start_date + ((item.start_period - 1) * 7)
      when :month then @start_date >> (item.start_period - 1)
      end
    end

    def item_finish(item)
      case @unit
      when :week then @start_date + ((item.start_period - 1 + item.duration_periods) * 7)
      when :month then @start_date >> (item.start_period - 1 + item.duration_periods)
      end
    end

    def task_payload(id:, parent_id:, name:, start:, finish:, milestone:)
      {
        id: id, parent_id: parent_id, name: name,
        start_date: start.iso8601, duration_days: (finish - start).to_i, milestone: milestone
      }
    end

    def run_java!(input_path, output_path)
      stdout, stderr, status = Open3.capture3("java", "-cp", classpath, "ScheduleToMspdi", input_path, output_path)
      raise JavaHelperError, "ScheduleToMspdi falhou: #{stderr.presence || stdout}" unless status.success?
    end

    def classpath
      "#{mpxj_jars_dir}/*:#{Rails.root.join('lib/java/build')}"
    end

    def mpxj_jars_dir
      Gem::Specification.find_by_name("mpxj").gem_dir + "/lib/mpxj"
    end
end
