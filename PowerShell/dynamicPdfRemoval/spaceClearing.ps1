
param(
    [string]$LogPath = "C:\LISPDFRemoval_Script\Logs"  # Change this to your desired log location
)

$TargetPaths = @(
    "C:\inetpub\z.bbtlabs.com",
    "C:\inetpub\lims.bbtlabs.com\REPORTSERVICE\data\Output",
    "C:\inetpub\lims.yungtrepreneur.com\Report\YM\ReportData",
    "C:\inetpub\i.bbtlabs.com",
    "C:\inetpub\r.bbtlabs.com",
    "C:\Log",
    "C:\Temp",
    "C:\inetpub\logs",
    "C:\LISPDFRemoval_Script\Logs",
    "E:\WebSites\i.bbtlabs.com",
    "E:\WebSites\r.bbtlabs.com",
    "E:\WebSites\z.bbtlabs.com"

    
    
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $TimeStampFile = Get-Date -Format "yyyy-MM-dd_HH"
    $LogMessage = "[$TimeStamp] [$Level] $Message"
    if (-not (Test-Path -Path $LogPath)) {
        New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    }
    $LogFile = Join-Path -Path $LogPath -ChildPath "FileCleanup_$TimeStampFile.log"
    Add-Content -Path $LogFile -Value $LogMessage
    Write-Host $LogMessage
}
$ScriptStartTime = Get-Date
Write-Log "Script execution started"
$Today = (Get-Date).Date
$Yesterday = $Today.AddDays(-1)
$CutoffDate = $Yesterday

Write-Log "Cutoff date set to: $($CutoffDate.ToString('yyyy-MM-dd'))"
Write-Log "Any files or folders modified before this date will be deleted"

$FilesDeleted = 0
$FoldersDeleted = 0
$FilesSkipped = 0
$FoldersSkipped = 0
$ErrorCount = 0
$TotalSizeReclaimed = 0
$PathsProcessed = 0
$PathsSkipped = 0

function Process-Directory {
    param(
        [string]$DirectoryPath,
        [int]$Level = 0
    )
    
    if (-not (Test-Path -Path $DirectoryPath)) {
        return
    }
    
    $Indent = "  " * $Level
    Write-Log "$($Indent)Processing directory: $DirectoryPath"
    
    try {
        $Files = Get-ChildItem -Path $DirectoryPath -File -ErrorAction Stop
        foreach ($File in $Files) {
            if ($File.LastWriteTime.Date -lt $CutoffDate) {
                $FileSize = $File.Length
                try {
                    Remove-Item -Path $File.FullName -Force -ErrorAction Stop
                    $script:FilesDeleted++
                    $script:TotalSizeReclaimed += $FileSize
                    Write-Log "$($Indent)  Deleted file: $($File.FullName) (Last modified: $($File.LastWriteTime), Size: $([Math]::Round($FileSize/1KB, 2)) KB)"
                }
                catch {
                    $script:ErrorCount++
                    Write-Log "$($Indent)  Failed to delete file: $($File.FullName) - $($_.Exception.Message)" -Level "ERROR"
                }
            }
            else {
                $script:FilesSkipped++
                Write-Log "$($Indent)  Skipped file: $($File.FullName) (Last modified: $($File.LastWriteTime))"
            }
        }
    }
    catch {
        $script:ErrorCount++
        Write-Log "$($Indent)Error accessing files in $DirectoryPath - $($_.Exception.Message)" -Level "ERROR"
    }
    
    try {
        $Folders = Get-ChildItem -Path $DirectoryPath -Directory -ErrorAction Stop
        
        foreach ($Folder in $Folders) {
            $HasRecentContent = $false
            
            $RecentItems = Get-ChildItem -Path $Folder.FullName -Recurse -ErrorAction SilentlyContinue | 
                          Where-Object { $_.LastWriteTime.Date -ge $CutoffDate }
            
            if ($RecentItems.Count -gt 0) {
                $HasRecentContent = $true
                Write-Log "$($Indent)  Folder has recent content: $($Folder.FullName)"
                Process-Directory -DirectoryPath $Folder.FullName -Level ($Level + 1)
            }
            else {
                try {
                    $FolderSize = (Get-ChildItem -Path $Folder.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                    
                    Remove-Item -Path $Folder.FullName -Recurse -Force -ErrorAction Stop
                    $script:FoldersDeleted++
                    $script:TotalSizeReclaimed += $FolderSize
                    Write-Log "$($Indent)  Deleted folder and all contents: $($Folder.FullName) (Last modified: $($Folder.LastWriteTime), Size: $([Math]::Round($FolderSize/1MB, 2)) MB)"
                }
                catch {
                    $script:ErrorCount++
                    Write-Log "$($Indent)  Failed to delete folder: $($Folder.FullName) - $($_.Exception.Message)" -Level "ERROR"
                }
            }
        }
    }
    catch {
        $script:ErrorCount++
        Write-Log "$($Indent)Error accessing subdirectories in $DirectoryPath - $($_.Exception.Message)" -Level "ERROR"
    }
}

foreach ($Path in $TargetPaths) {
    Write-Log "=========================================="
    Write-Log "Starting cleanup for target path: $Path"
    
    if (-not (Test-Path -Path $Path)) {
        Write-Log "Target directory does not exist: $Path" -Level "WARNING"
        $PathsSkipped++
        continue
    }
    
    try {
        Process-Directory -DirectoryPath $Path
        $PathsProcessed++
    }
    catch {
        Write-Log "Critical error processing path $Path : $($_.Exception.Message)" -Level "ERROR"
        $ErrorCount++
        $PathsSkipped++
    }
    
    Write-Log "Completed cleanup for target path: $Path"
}

$ScriptEndTime = Get-Date
$ExecutionTime = $ScriptEndTime - $ScriptStartTime

Write-Log "=== Cleanup Summary ==="
Write-Log "Target paths processed: $PathsProcessed"
Write-Log "Target paths skipped: $PathsSkipped"
Write-Log "Files deleted: $FilesDeleted"
Write-Log "Folders deleted: $FoldersDeleted"
Write-Log "Files skipped (recent): $FilesSkipped"
Write-Log "Folders skipped (containing recent items): $FoldersSkipped"
Write-Log "Errors encountered: $ErrorCount"
Write-Log "Total space reclaimed: $([Math]::Round($TotalSizeReclaimed/1MB, 2)) MB"
Write-Log "Script execution time: $($ExecutionTime.TotalSeconds) seconds"
Write-Log "Script execution completed"