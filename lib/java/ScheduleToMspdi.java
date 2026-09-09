// Helper standalone, chamado via `java` a partir de Rag::Schedule... não, de
// app/services/schedule_mspdi_exporter.rb (CLAUDE.md seção 8). Constrói um org.mpxj.ProjectFile
// a partir de um JSON simples (gerado pelo Ruby a partir dos ScheduleItem) e grava em MSPDI — o
// XML de intercâmbio do MS Project, que o MS Project abre nativamente (Arquivo > Abrir) e importa
// como projeto completo. Não existe biblioteca (Ruby ou não, fora de produtos pagos .NET/Java)
// capaz de gravar o binário .mpp de verdade — o formato nunca foi documentado pra escrita, só
// engenharia reversa parcial pra leitura. MSPDI é o caminho padrão de qualquer integração.
//
// Reaproveita os mesmos .jar que a gem `mpxj` já vendoriza (lib/mpxj/*.jar, inclusive Jackson
// pro parse do JSON) — não precisa de nenhuma dependência nova. Compilado uma vez
// (bin/build_java_helpers), o .class fica versionado; produção só precisa de JRE (`java`), não
// de JDK.
//
// Uso: java -cp "<gem>/lib/mpxj/*:lib/java/build" ScheduleToMspdi input.json output.xml
//
// Formato do input.json:
//   { "name": "Cronograma do Serviço - Cliente X", "start_date": "2026-10-01",
//     "tasks": [
//       { "id": 1, "parent_id": null, "name": "Mobilização", "start_date": "2026-10-01",
//         "duration_days": 7, "milestone": false },
//       { "id": 2, "parent_id": 1, "name": "Assinatura do Contrato", "start_date": "2026-10-01",
//         "duration_days": 1, "milestone": true }
//     ] }
// Só 1 nível de hierarquia (fase -> atividade), igual ScheduleItem — parent_id aponta pro "id" da
// fase; fase em si tem parent_id null. Datas em dias corridos (sem calendário de dias úteis),
// mesma convenção do ScheduleTableBuilder — nenhuma conta de dia útil entra aqui.
//
// TaskMode.MANUALLY_SCHEDULED em TODA tarefa (achado ao vivo, 2026-09, com o .xml real de uma
// proposta aberto no MS Project de verdade — não só MPXJ::Reader): mesmo com Start/Finish
// corretos e distintos por tarefa gravados no arquivo (conferido lendo o XML gerado, cada uma com
// sua própria data), o MS Project mostrava TODAS as tarefas começando no mesmo dia — o início do
// projeto. Causa: toda tarefa nasce AUTO_SCHEDULED (padrão de project.addTask()/parent.addTask())
// e sem predecessora nenhuma (este cronograma não tem dependência entre atividades, só posição no
// tempo) — o motor de CPM do Project, ao abrir/recalcular, agenda tarefa auto sem predecessora
// como "o quanto antes" a partir do início do projeto, ignorando o <Start> literal do arquivo.
// MANUALLY_SCHEDULED desliga esse recálculo: o Project usa exatamente o Start/Finish do arquivo,
// sem tentar re-agendar nada — é literalmente pra isso que existe (plano já pronto, não uma
// dependência pro Project inferir). Resolve de vez também o problema de calendário de
// dias úteis × dias corridos que motivou o ELAPSED_DAYS de uma correção anterior: tarefa manual
// não deriva Finish de Start+Duration, então a distinção deixou de importar pra correção — Duration
// volta a ser TimeUnit.DAYS puro (mesmo número de dias corridos de sempre, só que sem o rótulo
// "elapsed" que o Project mostra em português como "Xdiasd", em vez do "X dias" limpo).
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.mpxj.Duration;
import org.mpxj.ProjectFile;
import org.mpxj.Task;
import org.mpxj.TaskMode;
import org.mpxj.TimeUnit;
import org.mpxj.mspdi.MSPDIWriter;

import java.io.File;
import java.io.FileOutputStream;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.Map;

public class ScheduleToMspdi {
  public static void main(String[] args) throws Exception {
    if (args.length != 2) {
      System.err.println("Uso: ScheduleToMspdi input.json output.xml");
      System.exit(1);
    }

    JsonNode root = new ObjectMapper().readTree(new File(args[0]));

    ProjectFile project = new ProjectFile();
    project.getProjectConfig().setAutoOutlineLevel(true);
    project.getProjectConfig().setAutoWBS(true);
    project.addDefaultBaseCalendar();

    project.getProjectProperties().setProjectTitle(root.path("name").asText());
    project.getProjectProperties().setName(root.path("name").asText());
    project.getProjectProperties().setStartDate(parseDate(root.path("start_date").asText()));

    Map<Integer, Task> tasksById = new HashMap<>();

    for (JsonNode node : root.path("tasks")) {
      int id = node.path("id").asInt();
      JsonNode parentIdNode = node.path("parent_id");
      Task parent = (parentIdNode.isNull() || parentIdNode.isMissingNode())
        ? null
        : tasksById.get(parentIdNode.asInt());

      Task task = (parent == null) ? project.addTask() : parent.addTask();
      task.setName(node.path("name").asText());
      task.setTaskMode(TaskMode.MANUALLY_SCHEDULED);

      LocalDateTime start = parseDate(node.path("start_date").asText());
      boolean milestone = node.path("milestone").asBoolean(false);
      // Marco sai sempre com duração 0 no MSPDI (convenção do MS Project) — mesmo que
      // ScheduleItem exija duration_periods >= 1 (regra correta pro Gantt do .docx, não muda
      // aqui: essa duração ainda é 1 período, só não é a que vai pro MS Project).
      int durationDays = milestone ? 0 : node.path("duration_days").asInt();
      task.setStart(start);
      task.setFinish(start.plusDays(durationDays));
      task.setDuration(Duration.getInstance(durationDays, TimeUnit.DAYS));
      task.setMilestone(milestone);

      tasksById.put(id, task);
    }

    try (FileOutputStream out = new FileOutputStream(args[1])) {
      new MSPDIWriter().write(project, out);
    }

    System.out.println("OK");
  }

  private static LocalDateTime parseDate(String isoDate) {
    return LocalDate.parse(isoDate).atStartOfDay();
  }
}
