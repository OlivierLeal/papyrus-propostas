require "test_helper"

class Rag::SectionChunkerTest < ActiveSupport::TestCase
  test "quebra o texto nas seções numeradas do padrão Papyrus" do
    chunks = Rag::SectionChunker.new(<<~TEXT).call
      Lauro de Freitas-BA, 06 de setembro de 2021.

      Ref.: Proposta de serviços técnicos para obtenção da Licença Prévia do PEOL JASMIM.
      #{"Texto de apresentação da carta que precede o sumário. " * 3}

      3. OBJETIVO DOS SERVIÇOS

      #{"Realizar serviços técnicos de assessoria e elaboração de Estudos Ambientais. " * 3}

      4. ESCOPO E METODOLOGIA DO SERVIÇO

      #{"A definição do escopo utilizou como base os documentos fornecidos pelo cliente. " * 3}
    TEXT

    assert_equal [ nil, "3", "4" ], chunks.map(&:section_number)
    assert_equal "Preâmbulo", chunks.first.section_title
    assert_equal "OBJETIVO DOS SERVIÇOS", chunks.second.section_title
    assert_equal (0..2).to_a, chunks.map(&:position)
  end

  test "não promove a seção uma linha numerada no meio de um parágrafo" do
    chunks = Rag::SectionChunker.new(<<~TEXT).call
      1. PRODUTOS A SEREM ENTREGUES

      Os formatos aceitos para entrega dos produtos digitais são os seguintes:
      3 DOCX, KMZ, KML, XLS/XLSX E IMAGENS EM ALTA RESOLUÇÃO
      #{"Complemento do mesmo parágrafo para o bloco ter tamanho suficiente. " * 3}
    TEXT

    assert_equal 1, chunks.size
    assert_equal "PRODUTOS A SEREM ENTREGUES", chunks.first.section_title
    assert_includes chunks.first.content, "DOCX, KMZ, KML"
  end

  test "reconhece títulos consecutivos sem linha em branco entre eles" do
    chunks = Rag::SectionChunker.new(<<~TEXT).call
      1.1 IDENTIFICAÇÃO DO EMPREENDEDOR
      1.2 IDENTIFICAÇÃO DA EMPRESA RESPONSÁVEL PELOS ESTUDOS

      #{"Papyrus Consultoria Ambiental, CNPJ 07.946.358/0001-50, Lauro de Freitas. " * 3}
    TEXT

    assert_equal [ "1.2" ], chunks.map(&:section_number)
    assert_equal "IDENTIFICAÇÃO DA EMPRESA RESPONSÁVEL PELOS ESTUDOS", chunks.first.section_title
  end

  test "seção longa é dividida em chunks que cabem no limite do modelo de embedding" do
    body = (1..40).map { |i| "Parágrafo #{i} do escopo com texto suficiente para somar volume. " * 2 }.join("\n\n")
    chunks = Rag::SectionChunker.new("4. ESCOPO E METODOLOGIA DO SERVIÇO\n\n#{body}").call

    assert_operator chunks.size, :>, 1
    assert chunks.all? { |chunk| chunk.char_count <= Rag::SectionChunker::MAX_CHARS }
    assert chunks.all? { |chunk| chunk.section_number == "4" }, "todo chunk mantém a seção de origem"
  end

  test "fragmento órfão é anexado ao chunk anterior em vez de virar entrada solta" do
    body = "#{'Descrição longa da equipe técnica multidisciplinar do projeto. ' * 40}\n\nGeógrafo."
    chunks = Rag::SectionChunker.new("7. EQUIPE TÉCNICA\n\n#{body}").call

    assert chunks.none? { |chunk| chunk.char_count < Rag::SectionChunker::MIN_CHARS }
    assert_includes chunks.last.content, "Geógrafo."
  end

  test "juntar um fragmento órfão nunca estoura o limite do modelo de embedding" do
    # Regressão: o merge de órfãos ignorava o teto e produzia chunk de ~1996 caracteres
    # (≈525 tokens), acima dos 512 do cohere.embed-multilingual-v3 — a cauda era truncada
    # silenciosamente pelo modelo.
    body = "#{'Parágrafo com bastante texto para encher o limite do modelo. ' * 60}\n\nÓrfão."
    chunks = Rag::SectionChunker.new("4. ESCOPO E METODOLOGIA\n\n#{body}").call

    assert chunks.all? { |chunk| chunk.char_count <= Rag::SectionChunker::MAX_CHARS },
      "maior chunk teve #{chunks.map(&:char_count).max} caracteres"
  end

  test "descarta seção curta demais para ter valor de busca" do
    chunks = Rag::SectionChunker.new("8. ANEXOS\n\nVide anexo.\n").call

    assert_empty chunks
  end
end
