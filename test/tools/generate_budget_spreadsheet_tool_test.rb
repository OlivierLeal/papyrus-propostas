require "test_helper"

class GenerateBudgetSpreadsheetToolTest < ActiveSupport::TestCase
  setup do
    @proposal = proposals(:priced_proposal)
    @proposal.project_pricing.recalculate!
  end

  test "anexa a planilha aos documentos gerados, no formato do card de download" do
    result = JSON.parse(GenerateBudgetSpreadsheetTool.new(proposal: @proposal).execute)

    assert result["success"], result["error"]
    assert_equal [ @proposal.budget_spreadsheet_filename ], result["filenames"]
    document = @proposal.reload.generated_documents.last
    assert_equal "budget_spreadsheet", document.blob.metadata["kind"]
    assert_equal @proposal.version, document.blob.metadata["version"]
    assert_match "células amarelas", result["message"]
  end

  test "nome sem revisão e com o sufixo da planilha" do
    @proposal.update!(docx_filename_override: "PTC26055_Mineração MJS_EDA+MQAR_Rev.03")

    assert_equal "PTC26055_Mineração MJS_EDA+MQAR_Planilha_Orcamentaria.xlsx", @proposal.budget_spreadsheet_filename
  end
end
