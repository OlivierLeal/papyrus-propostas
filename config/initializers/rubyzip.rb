# Sem isso, o rubyzip escreve extensões ZIP64 na entrada que a gente edita (word/document.xml)
# mas não no resto do arquivo .docx — esse header inconsistente faz o Word e o LibreOffice
# recusarem o arquivo como corrompido, mesmo com o conteúdo em si intacto (visto em rubyzip 3.4.1
# ao usar Zip::File#get_output_stream para editar uma entrada de um .docx existente).
Zip.write_zip64_support = false
