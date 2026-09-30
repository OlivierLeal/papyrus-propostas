# Dados fixos da Papyrus (config/papyrus_company.yml) — razão social, CNPJ, tributos e a decomposição
# do BDI que planilhas de formação de preço pedem. Valor ausente = a Papyrus ainda não informou.
class PapyrusCompany
  PATH = Rails.root.join("config/papyrus_company.yml")

  def self.data
    @data = nil if Rails.env.local? # recarrega em dev/test sem reiniciar
    @data ||= YAML.safe_load_file(PATH).deep_stringify_keys
  end

  def self.[](key) = data[key.to_s]
  def self.tributo(name) = data.dig("tributos", name.to_s)
  def self.bdi_componente(name) = data.dig("bdi_componentes", name.to_s)
end
