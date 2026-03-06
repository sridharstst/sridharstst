

#param (
    #$version,
   # $buildNumber,
   # $FTEBaseData
#)
Import-Module W:\Automation_Script\Functions\Functions.psm1
Import-Module WebAdministration
$version = "V1.0.0.1"
$buildNumber = 159
$FTEBaseData = "UATQA"

Write-Output "Version : $version"
Write-Output "BuildNumber :$buildNumber"
Write-Output "FTEBaseData : $FTEBaseData"

#Set-Location "R:\RMG_Auto\Script"
#$credPath = ".\Encrypt\Xml\credential.xml"
#$cred = Import-CliXml $credPath

$fTEFunction = @("dbo.fun_DaysCalculation.UserDefinedFunction.sql")
$fTETables = @("dbo.MachineResults.Table.sql")
$fTEProcedure = @("pro_GetClientSubUser.sql")

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "Log_$Version-$buildNumber.log"
$logPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Logs\db"
$LogFullPath = Join-Path -Path $logPath -ChildPath $logFile
$ServerInstance = ""
$DatabaseName = "
#$username = $cred.UserName
#$sqlPass = $cred.GetNetworkCredential().Password
$username = ""
$sqlPass=''
$localDestPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Migrated_Source\db"
$numRecentLogs = 4
$SourcePath = "R:\Jenkins_Release\LIS_ENT_QA\DB"  
$filename = "entQA-lis-db"
$appPoolName = "LIMS_ENT_QA_Service"
$latestPathFile = "$filename-$version-$buildNumber"
$scriptPath = @("FUNCTIONS", "PROCEDURES", "TABLES", "BASEDATA")
$latestPath = Join-Path -Path $localDestPath -ChildPath $latestPathFile
$globalErrors = $false
$ErrorActionPreference = 'Stop'
$ReportBackupFolder = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Backups\Report"
$reportBackupfile = Join-Path -Path $ReportBackupFolder -ChildPath "Backup_$Version-$buildNumber"
$reportSourcePath = "R:\Jenkins_Release\LIS_ENT_QA\Report"
$reportDestPath = "W:\LIMS_ENTERPRISE_QA\WEBSITE\REPORTSERVICE\Data\ReportFiles"
$reportLocalDestPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Migrated_Source\Report"
$reportFile = "entQA-lis-report"
$reportFileName = "$reportFile-$version-$buildNumber"
$reportFullPath = Join-Path -Path $reportLocalDestPath -ChildPath $reportFileName
$numRecentBackups = 3


# MAIN_SCript and using the functions from the function.psm1 that imported

if(!(Test-Path $LogFullPath))
{
    $LogFullPath = Join-Path -Path $logPath -ChildPath "Log_$Timestamp-$Version-$buildNumber.log"
}
Start-Transcript -Path $LogFullPath
write-host "starting Script"
Remove-OldLogs -numRecentLogs $numRecentLogs
Copy-File -destPath $localDestPath -filename $filename -dmzSourcePath $SourcePath -version $Version -buildNumber $buildNumber -latestPath $latestPath
Copy-File -destPath $reportLocalDestPath -filename $reportFile -dmzSourcePath $reportSourcePath -version $Version -buildNumber $buildNumber -latestPath $reportFullPath
write-Host "copied the file form Jenkins-Release to local"


try {
    Write-Host "started the Backup for report"
    #$BackupErros = Backup-Data -webSitePath $reportDestPath -folder $reportBackupfile -backupPath $ReportBackupFolder -numRecentBackups $numRecentBackups
    #if ($BackupErros) {
   #     Write-Host "Backup for report completed with errors!" -ForegroundColor Red
    #    $globalErrors = $true
    #}
   # else {
    ##    Write-Host "Backup for report Completed successfully" -ForegroundColor Green
    #}
} catch {
   # Write-Host "Backup for Report failed: $_" -ForegroundColor Red
   # $globalErrors = $true
}
 

try {
   # $functionErrors = functionsscript -sourcePath $latestPath -scriptPath "$($scriptPath[0])" -filesToExclude @($fTEFunction) -server $ServerInstance -username $username -pass $sqlPass -database $DatabaseName
   # if ($functionErrors) {
   #     Write-Host "Functions completed with errors!" -ForegroundColor Red
   #     $globalErrors = $true
   # } else {
   #     Write-Host "Functions completed successfully" -ForegroundColor Green
   # }
} catch {
   # Write-Host "Functions failed: $_" -ForegroundColor Red
   # $globalErrors = $true
}

try {
    Write-Host "`n"
    Write-Host "Going to run the table script`n"
   # $tableErrors = TableScript -sourcePath $latestPath -scriptPath "$($scriptPath[2])" -filesToExclude @($fTETables) -server $ServerInstance -username $username -pass $sqlPass -database $DatabaseName
   # if ($tableErrors) {
    #    Write-Host "Table scripts completed with errors!" -ForegroundColor Red
   #     $globalErrors = $true
   # } else {
   #     Write-Host "Table scripts completed successfully" -ForegroundColor Green
   # }
} catch {
   # Write-Host "Table failed: $_" -ForegroundColor Red
   # $globalErrors = $true
}

try {
    Write-Host "`n"
    Write-Host "Going to run the procedure script`n" 
  #  $procedureErrors = Procedurescript -sourcePath $latestPath -scriptPath "$($scriptPath[1])" -filesToExclude @($fTEProcedure) -server $ServerInstance -username $username -pass $sqlPass -database $DatabaseName
   # if ($procedureErrors) {
   #     Write-Host "Procedure scripts completed with errors!" -ForegroundColor Red
   #     $globalErrors = $true
   # } else {
   #     Write-Host "Procedure scripts completed successfully" -ForegroundColor Green
   # }
} catch {
    #Write-Host "Procedures failed: $_" -ForegroundColor Red
   # $globalErrors = $true
}

try {
    Write-Host "`n"
    Write-Host "Going to run the Basedata script`n"
   # $basedataErrors = Basedatascript -sourcePath $latestPath -scriptPath "$($scriptPath[3])" -env $FTEBaseData -server $ServerInstance -username $username -pass $sqlPass -database $DatabaseName
   # if ($basedataErrors) {
   #     Write-Host "Basedata scripts completed with errors!" -ForegroundColor Red
   #     $globalErrors = $true
   # } else {
    #    Write-Host "Basedata scripts completed successfully" -ForegroundColor Green
    #}
} catch {
   # Write-Host "Basedata failed: $_" -ForegroundColor Red
   # $globalErrors = $true
}

try {
    Write-Host "`n"
    Write-Host "Replacing the Latest to Report"
    $reportErros = Copy-Report -sourcePath $reportFullPath  -destPath $reportDestPath
    if ($reportErrors) 
    {
        Write-Host "While replace the latest to $reportDestPath completed with errors!" -ForegroundColor Red
        $globalErrors = $true
    } else 
    {
        Write-Host "latest replaced to $reportDestPath successfully" -ForegroundColor Green
    }

} catch 
{
    Write-Host "Report deployment is faild: $_" -ForegroundColor Red
    $globalErrors = $true
}



#Copy-Report -sourcePath $reportFullPath -destPath $reportDestPath

# Always restart the application pool
Restart-ApplicationPool -AppPoolName $appPoolName

# Final error reporting
if ($globalErrors) {
    Write-Host "`nScript completed with errors! Check the logs above." -ForegroundColor Red
    Stop-Transcript
    exit 1
} else {
    Write-Host "`nAll scripts completed successfully!" -ForegroundColor Green
    Stop-Transcript
    exit 0
}
Stop-Transcript

