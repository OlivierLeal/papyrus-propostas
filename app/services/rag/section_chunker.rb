module Rag
  # Etapa 3 do pipeline: quebra o texto em chunks para embedar.
  #
  # O corte NÃO é cego a cada N caracteres: as propostas da Papyrus seguem um sumário
  # numerado estável ("1. APRESENTAÇÃO SUMÁRIA", "3. OBJETIVO DOS SERVIÇOS", "10. PREÇO"),
  # e essa numeração é a fronteira semântica natural. Um chunk = um pedaço de seção, com o
  # título da seção preservado no metadado — que é o que permite ao retriever responder
  # "me traga o escopo de serviços de EIA-RIMA de eólica" e não um trecho solto no meio.
  class SectionChunker
    # cohere.embed-multilingual-v3 trunca em 512 tokens. Em PT-BR a razão fica perto de
    # 3,8 chars/token, então 1800 chars ≈ 470 tokens: cabe com folga, sem truncar.
    MAX_CHARS = 1800
    OVERLAP_CHARS = 200
    # Sobra de seção menor que isso não vira chunk próprio (assinatura, "vide anexo", número
    # de página solto) — é ruído que só suja o resultado da busca.
    MIN_CHARS = 120

    PREAMBLE_TITLE = "Preâmbulo"

    # Marcador que o TextExtractor põe na frente de um título que ele identificou com certeza
    # pelo ESTILO do parágrafo no DOCX (Ttulo1/Heading1). Nesse caso não há heurística a
    # aplicar: o autor do documento já disse que aquilo é um título.
    # Unit Separator: caractere de controle que não aparece em documento real, mas — ao
    # contrário do byte nulo — atravessa Postgres e chamadas de API sem quebrar nada. O
    # marcador é interno ao par TextExtractor/SectionChunker; quem consome o texto extraído
    # fora do pipeline de RAG deve usar Result#plain_text.
    HEADING_MARKER = "\u001F§"
    MARKED_HEADING = /\A#{HEADING_MARKER}(?<number>[\d.]*)\s*(?<title>.+)\z/
    # Só o marcador, para limpar o texto sem perder o título (ver TextExtractor::Result#plain_text).
    MARKED_HEADING_PREFIX = /#{HEADING_MARKER}(?=[\d.]*\s*)/

    # Numeração já digitada no início do título ("6.1 OBRIGAÇÕES DA PAPYRUS").
    LEADING_NUMBER = /\A\d+(?:\.\d+)*\.?\s+/

    # Título de seção: numeração + texto predominantemente em caixa alta (padrão do modelo).
    HEADING_PATTERN = /\A\s{0,20}(?<number>\d{1,2}(?:\.\d{1,2})*)[.\-–)]?\s+(?<title>\p{Lu}[\p{L}\p{N}\s\-–\/,ºª().:]{3,90})\s*\z/

    # Uma linha de tabela ("2 Fauna terrestre 40") também casaria o padrão acima. Exigir que o
    # título seja majoritariamente maiúsculo separa cabeçalho de seção de linha de conteúdo.
    MIN_UPPERCASE_RATIO = 0.6

    Chunk = Data.define(:position, :section_number, :section_title, :content, :char_count) do
      def estimated_tokens = (char_count / 3.8).round
    end

    def initialize(text)
      @text = text.to_s
    end

    def call
      position = -1

      split_into_sections.flat_map do |section|
        header = section_header(section)

        split_by_size(section[:body], reserve: header.length).filter_map do |body|
          content = header.empty? ? body : "#{header}\n\n#{body}"
          next if content.length < MIN_CHARS

          Chunk.new(
            position: position += 1,
            section_number: section[:number],
            section_title: section[:title],
            content: content,
            char_count: content.length
          )
        end
      end
    end

    private

    # Todo chunk carrega o título da própria seção no texto. Sem isso, um pedaço do meio de
    # "ESCOPO E METODOLOGIA" recuperado sozinho não diz de que parte da proposta veio — e o
    # título é justamente o sinal mais forte que o trecho tem para a busca por similaridade.
    def section_header(section)
      return "" if section[:title] == PREAMBLE_TITLE

      [ section[:number], section[:title] ].compact_blank.join(". ")
    end

    # Tudo que vem antes da primeira seção numerada (capa, carta de apresentação, sumário de
    # revisões) vira uma seção "preâmbulo" em vez de ser descartado — a carta costuma trazer
    # o objeto do serviço em uma frase, que é ótimo material de busca.
    def split_into_sections
      sections = [ { number: nil, title: PREAMBLE_TITLE, lines: [] } ]
      previous_blank = true
      previous_heading = false

      @text.each_line do |line|
        # Um título de seção vem depois de linha em branco OU logo depois de outro título
        # (blocos "1.1 / 1.2 / 1.3" aparecem colados). Exigir o contexto evita que uma linha
        # numerada no meio de um parágrafo ou de uma tabela seja promovida a seção e parta o
        # texto no lugar errado.
        heading = detect_heading(line) if previous_blank || previous_heading || line.start_with?(HEADING_MARKER)
        previous_blank = line.strip.empty?
        previous_heading = heading.present?

        if heading
          sections << { number: heading[:number], title: heading[:title], lines: [] }
        else
          sections.last[:lines] << line
        end
      end

      sections.filter_map do |section|
        body = section[:lines].join.gsub(/\n{3,}/, "\n\n").strip
        next if body.empty?

        section.except(:lines).merge(body: body)
      end
    end

    def detect_heading(line)
      if (marked = MARKED_HEADING.match(line.chomp))
        return { number: marked[:number].presence, title: marked[:title].squish }
      end

      match = HEADING_PATTERN.match(line.chomp)
      return nil unless match

      title = match[:title].strip
      letters = title.scan(/\p{L}/)
      return nil if letters.empty?

      uppercase_ratio = letters.count { |char| char == char.upcase }.fdiv(letters.length)
      return nil if uppercase_ratio < MIN_UPPERCASE_RATIO

      { number: match[:number], title: title.squish }
    end

    # Seção maior que o limite do modelo é quebrada em parágrafos, com sobreposição entre os
    # pedaços para não cortar uma frase relevante bem na fronteira.
    #
    # A invariante que importa aqui é "nenhum chunk passa do teto": o cohere.embed-multilingual-v3
    # trunca em 512 tokens sem avisar, então um chunk grande demais perde a cauda em silêncio.
    def split_by_size(body, reserve: 0)
      budget = MAX_CHARS - reserve - 2
      return [ body ] if body.length <= budget

      chunks = []
      current = +""

      paragraphs_within(body, budget).each do |paragraph|
        if current.length + paragraph.length + 2 > budget
          chunks << current.strip if current.strip.present?
          current = +continuation(current, paragraph, budget)
        end

        current << paragraph << "\n\n"
      end

      chunks << current.strip if current.strip.present?
      merge_orphans(chunks, budget)
    end

    # Parágrafo maior que o teto (tabela colada, lista sem quebra de linha) é fatiado ANTES da
    # montagem. Assim o laço acima só lida com pedaços que cabem, e a invariante vale em
    # todos os caminhos — inclusive quando o bloco acumulado ainda está curto.
    def paragraphs_within(body, budget)
      body.split(/\n{2,}/).flat_map do |paragraph|
        paragraph = paragraph.strip
        next [] if paragraph.empty?

        paragraph.length > budget ? paragraph.scan(/.{1,#{budget}}/m).map(&:strip) : [ paragraph ]
      end
    end

    # A sobreposição com o chunk anterior só entra se ainda sobrar espaço para o parágrafo:
    # contexto extra não vale truncar o conteúdo que ele deveria contextualizar.
    def continuation(previous, paragraph, budget)
      tail = previous.strip[-OVERLAP_CHARS..] || ""
      return "" if tail.blank? || tail.length + paragraph.length + 4 > budget

      "#{tail}\n\n"
    end

    # Um pedaço menor que MIN_CHARS sozinho não tem contexto para ser recuperado ("Geógrafo."),
    # mas jogá-lo fora perde conteúdo de tabela. Então ele volta para o fim do chunk anterior,
    # que é de onde foi cortado — desde que caiba: juntar sem olhar o teto empurra o chunk
    # acima do limite do modelo de embedding, que trunca a cauda sem avisar.
    def merge_orphans(chunks, budget)
      chunks.each_with_object([]) do |chunk, result|
        chunk = chunk.strip
        next if chunk.empty?

        if chunk.length < MIN_CHARS && result.any? && result.last.length + chunk.length + 1 <= budget
          result[-1] = "#{result.last}\n#{chunk}"
        else
          result << chunk
        end
      end
    end
  end
end
