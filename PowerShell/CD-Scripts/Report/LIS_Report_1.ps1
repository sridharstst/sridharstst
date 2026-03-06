
Import-Module R:\RMG_Auto\Functions\Function.psm1
Import-Module WebAdministration



$Version= "V1.0.0.1"
$Build = "10"

$webSitePath = "R:\LIS_DEVTEST_DuMMY\WEBSITESERVICE\REPORTSERVICE\Data\ReportFiles\1\1"
$backupPath = "R:\RMG_Auto\Backup\Report"
$timestamp = Get-Date -Format "HH-mm"
$logFile = "Log_$Version-$Build.log"
$logPath = "R:\RMG_Auto\Logs\Report"
$LogFullPath = Join-Path -Path $logPath -ChildPath $logFile
$filename = "rmg-lis-report"
$SourcePath = "R:\Jenkins_Release\RMG_LIS\Report"
$localDestPath = "R:\RMG_Auto\Migrate_Dest_Path\Report"
$numRecentBackups = 3
$numRecentLogs = 3
$latestPathFile = "$filename-$Version-$Build"
$latestPath = Join-Path -Path $localDestPath -ChildPath $latestPathFile
$date = Get-Date -Format "yyyyMMdd"
$Backupfolder = Join-Path -Path $backupPath -ChildPath "Backup_$date-$Version-$Build"
$BackTimeFolder = Join-Path -Path $backupPath -ChildPath "Backup_$date-$Timestamp-$Version-$Build"

if (Test-Path $LogFullPath) {
    $LogFullPath = Join-Path -Path $logPath -ChildPath "Log_$Timestamp-$Version-$Build.log"
}

Start-Transcript -Path $LogFullPath
Write-Host "Starting script"
Remove-OldLogs -numRecentLogs $numRecentLogs
Write-Host "Starting backup script"
Backup-Data -webSitePath $webSitePath -folder $Backupfolder -backupPath $backupPath -numRecentBackups $numRecentBackups -BackTimeFolder $BackTimeFolder

Copy-File -destPath $localDestPath -filename $filename -dmzSourcePath $SourcePath -version $Version -buildNumber $Build -latestPath $latestPath
$verified = Copy-Report -sourcePath $latestPath -destPath $webSitePath
if ($verified) {
    Write-Host "Copy verification successful"
} else {
    $verifyError = $_.Exception.Message
    Write-Warning "Copy verification failed: $verifyError"
}



Stop-Transcript