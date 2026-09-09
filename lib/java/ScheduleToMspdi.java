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
// Duration tem que ser TimeUnit.ELAPSED_DAYS, nunca TimeUnit.DAYS (achado ao vivo, 2026-09):
// toda tarefa nasce auto-agendada (Manual=0, é o padrão de project.addTask()/parent.addTask()) —
// o MS Project recalcula Start+Duration pelo CALENDÁRIO da tarefa assim que abre o arquivo, e
// TimeUnit.DAYS é dia ÚTIL (o calendário "Standard" de addDefaultBaseCalendar() é seg-sex). Com
// Start/Finish calculados aqui em dias CORRIDOS mas Duration gravada em dias úteis, o Finish que
// o Project mostra diverge do que foi calculado (reproduzido: 73 dias de desvio num cronograma de
// 6 meses) — o arquivo "abre certo" e parece bom no MPXJ::Reader (que só relê os bytes, sem rodar
// esse recálculo), mas fica torto de verdade dentro do Project. ELAPSED_DAYS ignora o calendário
// — Start + Duration bate com o Finish em qualquer dia da semana, com ou sem recálculo.
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.mpxj.Duration;
import org.mpxj.ProjectFile;
import org.mpxj.Task;
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

      LocalDateTime start = parseDate(node.path("start_date").asText());
      boolean milestone = node.path("milestone").asBoolean(false);
      // Marco sai sempre com duração 0 no MSPDI (convenção do MS Project) — mesmo que
      // ScheduleItem exija duration_periods >= 1 (regra correta pro Gantt do .docx, não muda
      // aqui: essa duração ainda é 1 período, só não é a que vai pro MS Project).
      int durationDays = milestone ? 0 : node.path("duration_days").asInt();
      task.setStart(start);
      task.setFinish(start.plusDays(durationDays));
      task.setDuration(Duration.getInstance(durationDays, TimeUnit.ELAPSED_DAYS));
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
