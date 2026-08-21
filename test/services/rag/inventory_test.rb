require "test_helper"

class Rag::InventoryTest < ActiveSupport::TestCase
  test "identifica número, cliente e assunto pelo nome da pasta do job" do
    with_acervo("25002_Renova Energia_Estudos-Ambientais" => %w[PT25002_Renova_LALPLU_Rev03.docx]) do |jobs|
      job = jobs.sole

      assert_equal "25002", job.numero
      assert_equal "Renova Energia", job.client_name
      assert_equal "Estudos Ambientais", job.subject
      assert job.identified?
    end
  end

  test "extrai número, revisão e ano de cada documento" do
    with_acervo("25001_Petrobras_Cetaceos" => [ "25001_Petrobras_Cetaceos_Rev00 20250104.docx" ]) do |jobs|
      item = jobs.sole.items.sole

      assert_equal "25001", item.numero_proposta
      assert_equal 0, item.revision
      assert_equal 2025, item.year
      assert_equal 64, item.sha256.length
      assert_not item.superseded
    end
  end

  test "mantém só a revisão mais alta de um mesmo documento" do
    files = %w[PT25002_Renova_LALPLU_Rev02.docx PT25002_Renova_LALPLU_Rev03.docx]

    with_acervo("25002_Renova_Estudos" => files) do |jobs|
      by_revision = jobs.sole.items.index_by(&:revision)

      assert by_revision[2].superseded, "a revisão 02 é a antiga"
      assert_not by_revision[3].superseded
    end
  end

  test "documento dentro de Desatualizados é marcado independente da revisão" do
    with_acervo("25001_Petrobras_Cetaceos" => [ "Desatualizados/24XX02_Petrobras_Cetaceos_Rev01.docx" ]) do |jobs|
      assert jobs.sole.items.sole.superseded
    end
  end

  test "varre subpastas com nomes inconsistentes entre jobs" do
    files = [ "Doc´s Clientes/ET_181 - Estudo.doc", "Doc´s Papyrus/PS/Propostas/Kalil/Proposta EPI.docx" ]

    with_acervo("25002_Renova_Estudos" => files) do |jobs|
      paths = jobs.sole.items.map(&:relative_path)

      assert_equal 2, paths.size
      assert paths.any? { |path| path.include?("Doc´s Clientes") }
      assert paths.any? { |path| path.include?("Kalil") }
    end
  end

  test "pasta de job fora do padrão entra sem metadado em vez de ser descartada" do
    with_acervo("propostas antigas" => %w[uma proposta qualquer.docx]) do |jobs|
      job = jobs.sole

      assert_not job.identified?
      assert_nil job.numero
      assert_equal 1, job.items.size
    end
  end

  test "associa a planilha irmã pelo número da proposta" do
    files = [ "PTC26038_SCGAS_Relatorio_REV00.pdf", "Docs Papyrus/PTC26038_Planilha de Analise.xlsx" ]

    with_acervo("26038_SCGAS_Relatorio" => files) do |jobs|
      item = jobs.sole.items.sole

      assert_equal "PTC26038_Planilha de Analise.xlsx", File.basename(item.spreadsheet_path)
    end
  end

  test "planilha sem número no nome não é associada a documento sem número" do
    with_acervo("job" => [ "manual.pdf", "planilha de precos.xlsx" ]) do |jobs|
      assert_nil jobs.sole.items.sole.spreadsheet_path
    end
  end

  test "arquivos soltos na raiz do acervo formam um job sem número" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PTC26012_Certel_EIA-RIMA_REV00.pdf"), "x")

      job = Rag::Inventory.new(dir).call.sole

      assert_not job.identified?
      assert_equal 1, job.items.size
    end
  end

  test "ignora diretórios de build para não confundir fixture de teste com proposta" do
    with_acervo("25001_Cliente_Assunto" => [ "node_modules/readme.pdf", "proposta.docx" ]) do |jobs|
      assert_equal [ "proposta.docx" ], jobs.sole.items.map(&:filename)
    end
  end

  private

  def with_acervo(jobs)
    Dir.mktmpdir do |root|
      jobs.each do |job_name, filenames|
        filenames.each do |filename|
          path = File.join(root, job_name, filename)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "conteúdo")
        end
      end

      yield Rag::Inventory.new(root).call
    end
  end
end
