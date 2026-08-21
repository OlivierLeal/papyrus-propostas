module Rag
  # Etapa 1 do pipeline de RAG (CLAUDE.md seção 11.1): varre a pasta do acervo e monta o
  # inventário do que existe, SEM ler conteúdo e SEM gastar um token sequer.
  #
  # O acervo real não é uma pilha de propostas soltas: é uma pasta por JOB, e dentro dela
  # convivem coisas de natureza muito diferente — a proposta da Papyrus, o TR e os anexos do
  # cliente, as planilhas internas de custo e as revisões velhas. Quem separa isso é o
  # Rag::DocumentClassifier; aqui só se estabelece a moldura (que job é, que arquivos tem) e
  # os sinais baratos que o classificador vai usar depois.
  #
  # O SHA256 de cada arquivo é o que dá idempotência ao pipeline: reprocessar a pasta não
  # re-embeda (nem re-cobra) o que não mudou.
  class Inventory
    DOCUMENT_EXTENSIONS = %w[.pdf .docx .doc].freeze
    # .doc (Word 97-2003) é binário, não zip — o TextExtractor converte via LibreOffice.
    SPREADSHEET_EXTENSIONS = %w[.xlsx .xlsm].freeze

    IGNORED_DIRECTORIES = %w[node_modules tmp log storage vendor coverage test spec public].freeze

    # Pasta de job: "25001_Petrobras_Cetaceos", "25002_Renova Energia_Estudos-Ambientais".
    # O número e o cliente vêm daqui, não do nome de cada arquivo — a pasta é a fonte mais
    # confiável que o acervo tem, já que os arquivos dentro dela seguem convenções variadas.
    JOB_PATTERN = /\A(?<numero>\d{4,6})_(?<cliente>[^_]+?)(?:_(?<assunto>.+))?\z/

    # Número da proposta no nome do arquivo, quando existe: PTC26012, PT25002, 25001.
    FILE_NUMBER = /\A(?:PTC?)?(\d{4,6})/i
    REVISION = /rev\.?\s*(\d+)/i

    # Sinal forte de versão velha, e o único que independe de convenção de nome.
    SUPERSEDED_DIRECTORY = /desatualizad/i

    # O número embute o ano em 2 dígitos (25001 → 2025). Acervo antigo pode fugir disso,
    # por isso o ano só é aceito dentro de uma janela plausível.
    YEAR_WINDOW = (1998..(Date.current.year + 1)).freeze

    Item = Data.define(
      :path, :filename, :relative_path, :sha256, :byte_size, :extension,
      :numero_proposta, :revision, :year, :superseded, :spreadsheet_path
    ) do
      # Nome sem revisão nem extensão: duas revisões do mesmo documento compartilham o stem,
      # que é como o inventário descobre qual delas é a mais nova.
      def stem
        File.basename(filename, File.extname(filename)).gsub(REVISION, "").squish.downcase
      end
    end

    Job = Data.define(:path, :name, :numero, :client_name, :subject, :items) do
      def identified? = numero.present?
    end

    def initialize(path)
      @root = Pathname.new(path).expand_path
    end

    def call
      raise ArgumentError, "Pasta não encontrada: #{@root}" unless @root.directory?

      job_directories.filter_map { |directory| build_job(directory) }
    end

    private

    # Cada subpasta de primeiro nível é um job. Arquivos soltos na raiz também formam um job
    # (sem número), para uma pasta simples de propostas continuar funcionando.
    def job_directories
      directories = @root.children.select { |child| child.directory? && !ignored_name?(child.basename.to_s) }
      directories.unshift(@root) if documents_in(@root, recursive: false).any?
      directories
    end

    def build_job(directory)
      recursive = directory != @root
      documents = documents_in(directory, recursive:)
      return nil if documents.empty?

      spreadsheets = index_spreadsheets(directory, recursive:)
      meta = directory == @root ? {} : parse_job_name(directory.basename.to_s)
      items = documents.sort.map { |file| build_item(file, spreadsheets) }

      Job.new(
        path: directory.to_s,
        name: directory.basename.to_s,
        numero: meta[:numero],
        client_name: meta[:cliente],
        subject: meta[:assunto],
        items: mark_superseded(items)
      )
    end

    def documents_in(directory, recursive:)
      files_in(directory, DOCUMENT_EXTENSIONS, recursive:)
    end

    def files_in(directory, extensions, recursive:)
      pattern = recursive ? "**/*" : "*"

      directory.glob(pattern).select do |file|
        file.file? && extensions.include?(file.extname.downcase) && !ignored?(file)
      end
    end

    # Se o acervo for apontado para uma pasta que também contém código, o glob varre
    # node_modules e afins e traz PDF de fixture de teste como se fosse proposta.
    def ignored?(file)
      file.relative_path_from(@root).each_filename.any? { |segment| ignored_name?(segment) }
    end

    def ignored_name?(segment)
      IGNORED_DIRECTORIES.include?(segment) || segment.start_with?(".")
    end

    # Planilha "irmã" = mesmo número de proposta no nome. É dela que sai a memória de cálculo
    # histórica (BDI, diárias, equipe) — ver Rag::PricingSheetReader.
    def index_spreadsheets(directory, recursive:)
      files_in(directory, SPREADSHEET_EXTENSIONS, recursive:)
        .group_by { |file| file.basename.to_s[FILE_NUMBER, 1] }
        .except(nil)  # planilha sem número no nome não é irmã de ninguém
    end

    def build_item(file, spreadsheets)
      basename = file.basename.to_s
      numero = basename[FILE_NUMBER, 1]

      Item.new(
        path: file.to_s,
        filename: basename,
        relative_path: file.relative_path_from(@root).to_s,
        sha256: Digest::SHA256.file(file).hexdigest,
        byte_size: file.size,
        extension: file.extname.downcase.delete("."),
        numero_proposta: numero,
        revision: basename[REVISION, 1]&.to_i,
        year: year_from(numero),
        superseded: file.each_filename.any? { |segment| segment.match?(SUPERSEDED_DIRECTORY) },
        spreadsheet_path: (spreadsheets[numero]&.first&.to_s if numero)
      )
    end

    # Duas revisões do mesmo documento ("..._Rev02.docx" e "..._Rev03.docx") aparecem lado a
    # lado na mesma pasta, sem nenhuma marcação. Indexar as duas enche a busca de variantes
    # quase idênticas, então só a revisão mais alta de cada documento fica valendo.
    def mark_superseded(items)
      newest = items.reject(&:superseded)
        .select { |item| item.revision }
        .group_by(&:stem)
        .transform_values { |group| group.max_by(&:revision).revision }

      items.map do |item|
        next item if item.superseded || item.revision.nil?
        next item if newest[item.stem] == item.revision

        item.with(superseded: true)
      end
    end

    # Pasta fora do padrão não é erro: o job entra no inventário sem metadado e a
    # identificação fica para o classificador, que também lê o conteúdo.
    def parse_job_name(basename)
      match = JOB_PATTERN.match(basename)
      return {} unless match

      {
        numero: match[:numero],
        cliente: match[:cliente].strip.presence,
        assunto: match[:assunto]&.tr("_-", "  ")&.squish.presence
      }
    end

    def year_from(numero)
      return nil if numero.blank? || numero.length < 3

      year = 2000 + numero[0, 2].to_i
      YEAR_WINDOW.cover?(year) ? year : nil
    end
  end
end
