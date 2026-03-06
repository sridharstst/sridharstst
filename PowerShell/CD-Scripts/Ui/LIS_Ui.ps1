param (
    [string]$Version,
    [string]$Build
)

Import-Module W:\Automation_Script\Functions\Functions.psm1
Import-Module WebAdministration



Write-Output "Version: $Version"
Write-Output "Build: $Build"

$webSitePath = "W:\LIMS_ENTERPRISE_QA\WEBSITE\BBTAPP\"
$webSitePathGMTApp = "W:\LIMS_ENTERPRISE_QA\WEBSITE\GMTAPP"
$webSitePathQMSApp = "W:\LIMS_ENTERPRISE_QA\WEBSITE\QMSApp"
$backupPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Backups\UI"
$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$logFile = "Log_$Version-$Build.log"
$logPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Logs\UI"
$LogFullPath = Join-Path -Path $logPath -ChildPath $logFile
$filesToCopy = @("assets", "reports")
$filename = "entQA-lis-ui"
$SourcePath = "R:\Jenkins_Release\LIS_ENT_QA\UI"
$localDestPath = "W:\Automation_Script\LIMS_ENTERPRISE_QA\Migrated_Source\UI"
$webSiteName = "LIMS_ENTERPRISE_QA"
$appPoolName = "LIMS_ENT_QA_BbtApp"
$numRecentBackups = 3
$numRecentLogs = 3
$latestPathFile = "$filename-$Version-$Build"
$latestPath = Join-Path -Path $localDestPath -ChildPath $latestPathFile
$Backupfolder = Join-Path -Path $backupPath -ChildPath "Backup_$Version-$Build"
$BackTimeFolder = Join-Path -Path $backupPath -ChildPath "Backup_$timestamp-$Timestamp-$Version-$Build"


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
$copyErrors = Copy-File -destPath $localDestPath -filename $filename -dmzSourcePath $SourcePath -version $Version -buildNumber $Build -latestPath $latestPath
$deployErrors = replace_latest_ui -destPath $webSitePath -sourcePath $latestPath -filesToCopy $filesToCopy
Write-Host "Deploying to GMTApp"
$deployErrorsGMTApp = replace_latest_ui -destPath $webSitePathGMTApp -sourcePath $latestPath -filesToCopy $filesToCopy
Write-Host "Deploying to QMSApp"
$deployErrorsQMSApp = replace_latest_ui -destPath $webSitePathQMSApp -sourcePath $latestPath -filesToCopy $filesToCopy

if ($verified) {
    Write-Host "Copy verification successful"
} else {
    $verifyError = $_.Exception.Message
    Write-Warning "Copy verification failed: $verifyError"
}

Start-ApplicationPool -appPoolName $appPoolName
Start-WebSites -webSiteName $webSiteName

Stop-Transcript