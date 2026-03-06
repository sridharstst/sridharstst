

Import-Module R:\RMG_Auto\Functions\Function.psm1
Import-Module WebAdministration
 
$Version
$Build
Write-Host "$version"
write-host "$Build"
$webSitePath = "R:\LIS_DEVTEST_DuMMY\WEBSITESERVICE\LIMSSERVICE"
$backupPath = "R:\RMG_Auto\Backup\Service"
$timestamp = Get-Date -Format "HH-mm"
$logFile = "Log_$Version-$Build.log"
$logPath = "R:\RMG_Auto\Logs\Service\"
$LogFullPath = Join-Path -Path $logPath -ChildPath $logFile
$filesToCopy = @("appsettings.json", "web.config")
$filename = "rmg-lis-svc"
$SourcePath = "R:\Jenkins_Release\RMG_LIS\Service"
$localDestPath = "R:\RMG_Auto\Migrate_Dest_Path\Service"
$webSiteName = "Automation_Dummy-service"
$appPoolName = "Automation_Dummy-service"
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
$verified = $false
Remove-OldLogs -numRecentLogs $numRecentLogs
Write-Host "Starting backup script"
Backup-Data -webSitePath $webSitePath -folder $Backupfolder -backupPath $backupPath -numRecentBackups $numRecentBackups -BackTimeFolder $BackTimeFolder
Write-Host "Stopping the application pool: $appPoolName"
Stop-ApplicationPool -appPoolName $appPoolName
Write-Host "Stopping the website: $webSiteName"
Stop-WebSites -webSiteName $webSiteName
Copy-File -destPath $localDestPath -filename $filename -dmzSourcePath $SourcePath -version $Version -buildNumber $Build -latestPath $latestPath
$verified = replace_latest_Service -destPath $webSitePath -sourcePath $latestPath -filesToCopy $filesToCopy

if ($verified) {
    Write-Host "Copy verification successful"
} else {
    $verifyError = $_.Exception.Message
    Write-Warning "Copy verification failed: $verifyError"
}

Start-ApplicationPool -appPoolName $appPoolName
Start-WebSites -webSiteName $webSiteName

Stop-Transcript

