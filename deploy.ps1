Set-Location '.\TestData'

Import-Module '..\ym-sql-helper.ps1' -Force

$reportFilePath = '.\deploy-report-3.xml'
$sqlFilePath = '.\deploy-3.sql'

SplitSqlPackageScript -ReportFilePath $reportFilePath -SqlFilePath $sqlFilePath
#ParallelExecAllScript -ConnString 'Server=,,1433;Initial Catalog=TestDB;Persist Security Info=False;User ID=sa;Password=password;MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;' -Parallelcount 4
