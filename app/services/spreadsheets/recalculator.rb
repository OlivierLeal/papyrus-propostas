require "open3"

module Spreadsheets
  # Recalcula a planilha preenchida no LibreOffice headless e devolve o resultado como Workbook (com
  # os valores das fórmulas já calculados). É a conferência de verdade de uma planilha de fórmulas
  # do cliente: o total que ELA calcula tem que bater com o total da proposta — conta nenhuma nossa
  # substitui isso. Sem LibreOffice no servidor, devolve nil (o preenchimento segue sem conferência).
  class Recalculator
    TIMEOUT = 90

    def self.call(bytes, extension) = new.call(bytes, extension)

    def call(bytes, extension)
      Dir.mktmpdir("recalc") do |dir|
        source = File.join(dir, "planilha#{extension}")
        File.binwrite(source, bytes)
        out_dir = File.join(dir, "out")
        # Perfil próprio: duas instâncias do LibreOffice com o mesmo perfil travam uma a outra.
        command = [ "soffice", "-env:UserInstallation=file://#{dir}/profile", "--headless",
                    "--convert-to", "xlsx", "--outdir", out_dir, source ]
        _out, err, status = Timeout.timeout(TIMEOUT) { Open3.capture3(*command) }
        converted = Dir.glob(File.join(out_dir, "*.xlsx")).first
        unless status.success? && converted
          Rails.logger.warn("[Spreadsheets::Recalculator] falhou: #{err.to_s.lines.first&.strip}")
          return nil
        end

        Workbook.open(File.binread(converted))
      end
    rescue Errno::ENOENT, Timeout::Error, Workbook::Error => e
      Rails.logger.warn("[Spreadsheets::Recalculator] #{e.class}: #{e.message}")
      nil
    end
  end
end
