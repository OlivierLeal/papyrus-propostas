# O texto que o CLIENTE lê nunca nomeia o órgão (pedido da Charlene, 2026-09): "o órgão ambiental".
# O prompt já proíbe, mas o nome vazou no infográfico do cronograma da PTC26047 ("Protocolo da 2ª
# RLP no INEMA", 2026-10). Rede de segurança pros textos curtos que vêm da IA (cronograma, marcos).
module OrganNames
  ACRONYMS = %w[INEMA IBAMA FEPAM CETESB INEA SEMA SEMAD SUPRAM SEMACE SEMAS SEMARH SEMMA IMA IAT IEMA IPAAM
                NATURATINS IMASUL CPRH SUDEMA IDEMA IGAM FEAM ADEMA IMAC SEDAM SEMAR SPRH ICMBio].freeze
  PATTERN = /\b(?:(no|na|ao|à|do|da|pelo|pela|com o|com a|com|junto ao|junto à)\s+)?(?:#{ACRONYMS.join('|')})\b/
  PREPOSITIONS = { "no" => "no", "na" => "no", "ao" => "ao", "à" => "ao", "do" => "do", "da" => "do", "pelo" => "pelo",
                   "pela" => "pelo", "com o" => "com o", "com a" => "com o", "com" => "com o", "junto ao" => "junto ao",
                   "junto à" => "junto ao" }.freeze

  def self.genericize(text)
    return text unless text.is_a?(String)

    text.gsub(PATTERN) do
      preposition = Regexp.last_match(1)
      preposition ? "#{PREPOSITIONS.fetch(preposition)} órgão ambiental" : "órgão ambiental"
    end
  end
end
