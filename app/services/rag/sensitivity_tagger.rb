module Rag
  # Marca cada chunk quanto ao que ele carrega de sensível.
  #
  # Serve a dois propósitos: (a) LGPD — poder excluir da recuperação trechos com dado
  # identificável de cliente; (b) blindar o princípio da seção 5 do CLAUDE.md — trecho
  # histórico com valor em R$ é REFERÊNCIA para a IA escrever texto, nunca insumo de cálculo.
  # Quem calcula preço continua sendo o motor determinístico.
  class SensitivityTagger
    MONEY = /R\$\s*\d/i
    CNPJ = /\b\d{2}\.\d{3}\.\d{3}\/\d{4}-\d{2}\b/
    CPF = /\b\d{3}\.\d{3}\.\d{3}-\d{2}\b/
    EMAIL = /\b[\w+.-]+@[\w-]+\.[\w.]+\b/
    PHONE = /\(\d{2}\)\s*\d{4,5}-?\d{4}/
    # Registro de conselho profissional identifica uma pessoa tão bem quanto um CPF.
    REGISTRATION = /\b(CRBio|CREA|CRQ|CRM|CAU|CRA|CRC|OAB|CRESS|CRP)[\s:\-]*\d/i
    BANK = /\b(ag[êe]ncia|conta corrente|banco do brasil|ita[úu]|bradesco|caixa econ[ôo]mica|pix)\b/i
    PRICING_TERMS = /\b(BDI|impostos?|desembolso|valor total|pre[çc]o global|parcela|honor[áa]rios?|or[çc]amento)\b/i

    Tags = Data.define(:sensitive, :contains_pricing, :reasons)

    def initialize(content)
      @content = content.to_s
    end

    def call
      reasons = []
      reasons << "money" if @content.match?(MONEY)
      reasons << "cnpj" if @content.match?(CNPJ)
      reasons << "cpf" if @content.match?(CPF)
      reasons << "email" if @content.match?(EMAIL)
      reasons << "phone" if @content.match?(PHONE)
      reasons << "bank" if @content.match?(BANK)
      reasons << "professional_registration" if @content.match?(REGISTRATION)
      reasons << "pricing_terms" if @content.match?(PRICING_TERMS)

      Tags.new(
        sensitive: reasons.intersect?(%w[cnpj cpf email phone bank money professional_registration]),
        contains_pricing: reasons.intersect?(%w[money pricing_terms]),
        reasons: reasons
      )
    end
  end
end
