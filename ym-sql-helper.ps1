function ImportSqlServer {

    if (!(Get-Module -ListAvailable -Name SqlServer)) {
        Write-Host "SqlServer Module does not exist"
        Install-Module -Name SqlServer -Force
    }
}

function SplitSqlPackageScript {
    param (
        [string]$ReportFilePath,
        [string]$SQLFilePath
    )

    [xml]$report = Get-Content $ReportFilePath
    $script = Get-Content $SQLFilePath

    foreach ($path in '.\PreSQL', '.\SplitSql', '.\OtherSQL') {

        If (Test-Path $path) {
            Remove-Item $path -Force -Recurse
        }
        New-Item $path -Type directory -Force
    }

    $drops = ($report.DeploymentReport.Operations.Operation | Where-Object { $_.name -eq 'Drop' }).Item
    $drops = ($drops | Where-Object { ($_.Type -eq 'SqlStatistic') -or ($_.Type -eq 'SqlSecurityPolicy') }).Value
    SplitSql -ScriptContent $script -TableNames $drops -TargetPath .\PreSQL

    $createTableAsSelects = ($report.DeploymentReport.Operations.Operation | Where-Object { $_.name -eq 'CreateTableAsSelect' }).Item.Value
    SplitSql -ScriptContent $script -TableNames $createTableAsSelects -TargetPath .\SplitSql

    $tableRebuilds = ($report.DeploymentReport.Operations.Operation | Where-Object { $_.name -eq 'TableRebuild' }).Item.Value
    SplitSql -ScriptContent $script -TableNames $tableRebuilds -TargetPath .\SplitSql
    
    $alterTables = (($report.DeploymentReport.Operations.Operation | Where-Object { $_.name -eq 'Alter' }).Item | Where-Object { $_.Type -eq 'SqlTable' }).Value
    SplitSql -ScriptContent $script -TableNames $alterTables -TargetPath .\SplitSql

    # SaveOtherSQL -ScriptContent $script -TargetPath .\OtherSQL
}

function SaveOtherSQL {
    param (
        $ScriptContent,
        $TargetPath
    )

    $sql = @()
    $continuous = $false;

    for ($i = 0; $i -lt $ScriptContent.Length; $i = $i + 1) {

        if ($ScriptContent[$i] -match '^\s*$') {

            if ($continuous) {
                continue
            }

            $continuous = $true
        }
        else {
            $continuous = $false
        }

        $sql += $ScriptContent[$i]
    }

    If (Test-Path $TargetPath) {
        Remove-Item $TargetPath -Force -Recurse
    }
    New-Item $TargetPath -Type directory -Force
    Set-Content -value $sql -Encoding unicode  -LiteralPath  ($TargetPath + '\other.sql')
}

Function SplitSql {
    param (
        $ScriptContent,
        $TableNames,
        $TargetPath
    )

    foreach ($table in $TableNames) {
        Write-Host $table 'is be extracted'

        $tableSQL = GetSQLScriptHead($ScriptContent);
        $tableEscape = $table.Replace('[', '\[').Replace(']', '\]').Replace('.', '\.')

        $beginMatch = 0
        for ($i = 41; $i -lt $ScriptContent.Length; $i = $i + 1) {

            if ($beginMatch -gt 0) {
                $tableSQL += $ScriptContent[$i]

                if ($ScriptContent[$i] -match '^GO\s*$') {
                    $beginMatch -= 1;
                }

                $ScriptContent[$i] = ''
            }
            else {

                switch ($ScriptContent[$i]) {
                    { $_ -eq '' } { break; }

                    { $_ -match ('^IF EXISTS \(select top 1 1 from ' + $tableEscape + '') } { 
                        
                        for ($x = $i; $x -gt 40; $x = $x - 1) {
                            
                            if ($ScriptContent[$x] -match '^/\*') {
                                
                                for ($x; $x -lt $i; $x = $x + 1) {

                                    $tableSQL += $ScriptContent[$x]
                                    $ScriptContent[$x] = ''
                                }
                                break
                            }
                        }
                        
                        $beginMatch = 1;                       
                        break; 
                    }

                    { $_ -match ('^PRINT N''Dropping SqlSecurityPolicy ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Dropping Default Constraint unnamed constraint on ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^PRINT N''Creating Default Constraint unnamed constraint on ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Dropping Primary Key unnamed constraint on ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^PRINT N''Creating Primary Key unnamed constraint on ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Dropping Column Store Index ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^PRINT N''Creating Column Store Index ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Create Table as Select on ' + $tableEscape + '') } { $beginMatch = 2; break; }
  
                    { $_ -match ('^PRINT N''Starting rebuilding table ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Altering Table ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    { $_ -match ('^PRINT N''Dropping Security policy ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^PRINT N''Dropping Statistic ' + $tableEscape + '') } { $beginMatch = 2; break; }

                    # drop or create Primary Key . PRINT PK name, but do not know it
                    # must be placed last
                    { $_ -match ('^PRINT N''Creating Primary Key ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^PRINT N''Dropping Primary Key ' + $tableEscape + '') } { $beginMatch = 2; break; }
                    { $_ -match ('^ALTER TABLE ' + $tableEscape + '') } {
                        
                        if (($ScriptContent[$i - 4] -match '^PRINT N''Creating Primary Key \[') -or ($ScriptContent[$i - 4] -match '^PRINT N''Dropping Primary Key \[')) {
                            
                            $tableSQL += $ScriptContent[$i - 4]
                            $tableSQL += $ScriptContent[$i - 3]
                            $tableSQL += $ScriptContent[$i - 2]
                            $tableSQL += $ScriptContent[$i - 1]

                            $ScriptContent[$i - 4] = ''
                            $ScriptContent[$i - 3] = ''
                            $ScriptContent[$i - 2] = ''
                            $ScriptContent[$i - 1] = ''
                        }
                        
                        $beginMatch = 1
                        break 
                    }
                }

                if ($ScriptContent[$i] -match ('^ALTER view') `
                        -or $ScriptContent[$i] -match ('^ALTER PROC')) { 
                    break;
                }

                if ($beginMatch -gt 0) {
                    $tableSQL += $ScriptContent[$i]
                    $ScriptContent[$i] = ''
                }
            }
        }

        $fileName = $table.Replace(']', '').Replace('[', '').Replace('.', '_').Replace('\', '_').Replace('/', '_')
        Set-Content -value  $tableSQL -Encoding unicode  -LiteralPath  ($TargetPath + '\' + $fileName + '.sql')
    }
}

Function GetSQLScriptHead {
    param (
        $ScriptContent
    )

    $result = @()

    foreach ($i in 0..40) {
        $result += $ScriptContent[$i]
    }

    return $result
}

Function ParallelExecAllScript {
    param (
        [string]$ConnString,
        [int]$Parallelcount = 4
    )

    ParallelExecSQL -TableSQLFilePath .\PreSQL\ -ConnString $ConnString -Parallelcount $Parallelcount

    ParallelExecSQL -TableSQLFilePath .\SplitSql\ -ConnString $ConnString -Parallelcount $Parallelcount

    ParallelExecSQL -TableSQLFilePath .\OtherSQL\ -ConnString $ConnString -Parallelcount $Parallelcount
}

Function ParallelExecSQL {
    param (
        [string]$TableSQLFilePath,
        [string]$ConnString,
        [int]$Parallelcount = 4
    )

    $files = @(Get-ChildItem $TableSQLFilePath)

    if ($files.Length -eq 0) {
        return
    }
    
    Remove-Job *

    $taskCount = $files.Length
    if ($Parallelcount -gt $files.Length) {
        $Parallelcount = $files.Length
    }

    $task = { 
        param (
            [string] $file, 
            [string] $connString
        )
        $completed = $true

        $start = Get-Date
        try {
            Import-Module .\InvokeSqlcmd.ps1 -Force

            InvokeSqlcmd -connectionString $connString -Inputfile $file
            #Invoke-Sqlcmd -connectionString $connString -Inputfile $file
        }
        catch {
            $completed = $false 
        }

        $end = Get-Date
        $total = $end - $start

        if ($completed) {
            Write-Host "[$total] $file Completed"
        }
        else {
            Write-Error "[$total] $file has an error occurred. $Error"
        }
    }

    foreach ($i in 1..$Parallelcount) {

        $job = Start-Job -WorkingDirectory $PSScriptRoot -ScriptBlock $task -Name "task$i" -ArgumentList $files[$i - 1].FullName, $ConnString
    }

    $nextIndex = $Parallelcount
    
    while (($nextIndex -lt $files.Length) -or ($taskCount -gt 0)) {

        $jobs = Get-Job
        foreach ($job in $jobs) {
            $state = [string]$job.State
            if (($state -eq "Completed") -or ($state -eq "Failed")) {
                Receive-Job -Job $job   
                Remove-Job $job
                $taskCount--
                if ($nextIndex -lt $files.Length) {   
                    $taskNumber = $nextIndex + 1
                    $job = Start-Job -WorkingDirectory $PSScriptRoot -ScriptBlock $task -Name "task$taskNumber" -ArgumentList $files[$nextIndex].FullName, $connString
                    $nextIndex++
                }
            }
        }
        Start-Sleep 1
    }
}