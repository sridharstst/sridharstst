# =====================================================
# SQL Server Backup Script with 7-Zip Compression
# Optimized for Large Databases (75GB+)
# =====================================================

# =====================================================
# CONFIGURATION SECTION
# =====================================================
$serverInstance = "StandardDb"
$backupDirectory = "B:\FullBackup"
$tempBackupDirectory = "B:\TempBackup"  # Temporary location for .bak files
$compressedBackupDirectory = "B:\CompressedBackup"  # Final compressed backups
$dateStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$retentionCount = 2  # Keep last 2 compressed backups
$logFile = "B:\BackupLogs\BackupLog_$dateStamp.txt"

# 7-Zip Configuration
$sevenZipPath = "C:\Program Files\7-Zip\7z.exe"  # Adjust if different
$compressionLevel = 5  # 0=store, 1=fastest, 5=normal, 9=ultra (5 is good balance for speed/size)
$compressionThreads = 4  # Use multiple CPU cores for faster compression

# Email notification settings
$enableEmailAlerts = $true
$smtpServer = "smtp.gmail.com"
$smtpPort = 587
$emailFrom = "your-email@gmail.com"
$emailTo = "admin@yourdomain.com"
$emailUsername = "your-email@gmail.com"
$emailPassword = "your-app-password"  # Use App Password for Gmail

# =====================================================
# INITIALIZATION
# =====================================================
$script:successCount = 0
$script:failCount = 0
$script:failedDatabases = @()
$script:backupStartTime = Get-Date

# Create directories if they don't exist
@($tempBackupDirectory, $compressedBackupDirectory, (Split-Path $logFile -Parent)) | ForEach-Object {
    if (-not (Test-Path $_)) {
        New-Item -Path $_ -ItemType Directory -Force | Out-Null
    }
}

# =====================================================
# LOGGING FUNCTION
# =====================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','SUCCESS','WARNING','ERROR')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Console output with colors
    switch ($Level) {
        'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
        'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
        'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
        default   { Write-Host $logMessage -ForegroundColor White }
    }
    
    # Write to log file
    Add-Content -Path $logFile -Value $logMessage
}

# =====================================================
# VALIDATE 7-ZIP INSTALLATION
# =====================================================
function Test-7ZipInstalled {
    if (-not (Test-Path $sevenZipPath)) {
        Write-Log "7-Zip not found at: $sevenZipPath" "ERROR"
        Write-Log "Please install 7-Zip from: https://www.7-zip.org/download.html" "ERROR"
        Send-FailureEmail "7-Zip not installed - Backup aborted"
        exit 1
    }
    Write-Log "7-Zip found at: $sevenZipPath" "SUCCESS"
}

# =====================================================
# EMAIL NOTIFICATION FUNCTION
# =====================================================
function Send-FailureEmail {
    param([string]$CustomMessage = "")
    
    if (-not $enableEmailAlerts) { return }
    
    $duration = (Get-Date) - $script:backupStartTime
    $subject = "🚨 SQL Backup FAILED - $serverInstance - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    
    $body = @"
<html>
<body style='font-family: Arial, sans-serif;'>
<h2 style='color: #d9534f;'>⚠️ SQL Server Backup Alert</h2>
<hr>
<p><strong>Server:</strong> $serverInstance</p>
<p><strong>Date:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
<p><strong>Duration:</strong> $($duration.ToString("hh\:mm\:ss"))</p>
<p><strong>Status:</strong> <span style='color: #d9534f; font-weight: bold;'>FAILED</span></p>
<hr>
<h3>Statistics:</h3>
<ul>
<li><strong>Successful Backups:</strong> $script:successCount</li>
<li><strong>Failed Backups:</strong> $script:failCount</li>
</ul>

$(if ($script:failedDatabases.Count -gt 0) {
"<h3 style='color: #d9534f;'>Failed Databases:</h3>
<ul>
$(($script:failedDatabases | ForEach-Object { "<li>$_</li>" }) -join "`n")
</ul>"
})

$(if ($CustomMessage) { "<p><strong>Error Details:</strong><br>$CustomMessage</p>" })

<hr>
<p style='color: #888; font-size: 12px;'>Log file: $logFile</p>
<p style='color: #888; font-size: 12px;'>This is an automated alert. Please investigate immediately.</p>
</body>
</html>
"@
    
    try {
        $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($emailUsername, $securePassword)
        
        Send-MailMessage `
            -SmtpServer $smtpServer `
            -Port $smtpPort `
            -UseSsl `
            -Credential $credential `
            -From $emailFrom `
            -To $emailTo `
            -Subject $subject `
            -Body $body `
            -BodyAsHtml `
            -Priority High `
            -ErrorAction Stop
        
        Write-Log "Alert email sent successfully to $emailTo" "SUCCESS"
    }
    catch {
        Write-Log "Failed to send email: $($_.Exception.Message)" "WARNING"
    }
}

# =====================================================
# CLEANUP OLD BACKUPS
# =====================================================
function Remove-OldBackups {
    Write-Log "Starting cleanup of old backups (keeping last $retentionCount)" "INFO"
    
    # Clean temporary backup directory completely
    if (Test-Path $tempBackupDirectory) {
        Get-ChildItem -Path $tempBackupDirectory -File | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Log "Temporary backup directory cleaned" "SUCCESS"
    }
    
    # Keep only the last N compressed backups (by date)
    $compressedFiles = Get-ChildItem -Path $compressedBackupDirectory -Filter "*.7z" | 
                       Sort-Object LastWriteTime -Descending
    
    if ($compressedFiles.Count -gt $retentionCount) {
        $filesToDelete = $compressedFiles | Select-Object -Skip $retentionCount
        foreach ($file in $filesToDelete) {
            Remove-Item $file.FullName -Force
            Write-Log "Deleted old backup: $($file.Name)" "INFO"
        }
    }
}

# =====================================================
# COMPRESS BACKUP FILE
# =====================================================
function Compress-BackupFile {
    param(
        [string]$SourceFile,
        [string]$DestinationFile
    )
    
    Write-Log "Compressing: $SourceFile" "INFO"
    $compressStart = Get-Date
    
    # 7-Zip command: -mx5 = compression level, -mmt = multi-threading
    $arguments = "a", "-t7z", "-mx=$compressionLevel", "-mmt=$compressionThreads", "-y", $DestinationFile, $SourceFile
    
    try {
        $process = Start-Process -FilePath $sevenZipPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru
        
        if ($process.ExitCode -eq 0) {
            $compressDuration = (Get-Date) - $compressStart
            $originalSize = (Get-Item $SourceFile).Length / 1GB
            $compressedSize = (Get-Item $DestinationFile).Length / 1GB
            $ratio = [math]::Round(($compressedSize / $originalSize) * 100, 2)
            
            Write-Log "Compression completed in $($compressDuration.ToString('mm\:ss'))" "SUCCESS"
            Write-Log "Original: $([math]::Round($originalSize, 2)) GB | Compressed: $([math]::Round($compressedSize, 2)) GB | Ratio: $ratio%" "SUCCESS"
            
            # Delete original .bak file after successful compression
            Remove-Item $SourceFile -Force
            Write-Log "Original backup file deleted: $SourceFile" "INFO"
            
            return $true
        }
        else {
            Write-Log "Compression failed with exit code: $($process.ExitCode)" "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Compression error: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# =====================================================
# MAIN BACKUP PROCESS
# =====================================================
try {
    Write-Log "==================================================" "INFO"
    Write-Log "SQL SERVER BACKUP STARTED" "INFO"
    Write-Log "==================================================" "INFO"
    
    # Validate 7-Zip
    Test-7ZipInstalled
    
    # Cleanup old backups first
    Remove-OldBackups
    
    # Load SQL Server module
    Write-Log "Loading SQL Server module..." "INFO"
    Import-Module SqlServer -ErrorAction Stop
    Write-Log "SQL Server module loaded successfully" "SUCCESS"
    
    # Define connection string
    $connectionString = "Server=$serverInstance;TrustServerCertificate=True;Integrated Security=True;Connection Timeout=300"
    
    # Get list of user databases
    Write-Log "Retrieving database list from $serverInstance..." "INFO"
    $databases = Invoke-Sqlcmd -ConnectionString $connectionString -Query @"
        SELECT name 
        FROM sys.databases 
        WHERE name NOT IN ('master','model','msdb','tempdb')
        AND state_desc = 'ONLINE'
        ORDER BY name
"@ -QueryTimeout 60
    
    Write-Log "Found $($databases.Count) database(s) to backup" "INFO"
    
    # Backup each database
    foreach ($db in $databases) {
        $dbName = $db.name
        $backupFile = Join-Path -Path $tempBackupDirectory -ChildPath "$($dbName)_FullBackup_$dateStamp.bak"
        $compressedFile = Join-Path -Path $compressedBackupDirectory -ChildPath "$($dbName)_FullBackup_$dateStamp.7z"
        
        Write-Log "------------------------------------------------" "INFO"
        Write-Log "Processing database: $dbName" "INFO"
        
        try {
            # SQL Backup with verification
            $backupStart = Get-Date
            $sqlBackupQuery = @"
                BACKUP DATABASE [$dbName] 
                TO DISK = N'$backupFile' 
                WITH INIT, 
                     CHECKSUM, 
                     STATS = 10
"@
            
            Write-Log "Creating backup file..." "INFO"
            Invoke-Sqlcmd -ConnectionString $connectionString -Query $sqlBackupQuery -QueryTimeout 7200
            
            $backupDuration = (Get-Date) - $backupStart
            Write-Log "Backup completed in $($backupDuration.ToString('mm\:ss'))" "SUCCESS"
            
            # Verify backup integrity
            Write-Log "Verifying backup integrity..." "INFO"
            $verifyQuery = "RESTORE VERIFYONLY FROM DISK = N'$backupFile' WITH CHECKSUM"
            Invoke-Sqlcmd -ConnectionString $connectionString -Query $verifyQuery -QueryTimeout 600
            Write-Log "Backup verification passed" "SUCCESS"
            
            # Compress the backup
            if (Compress-BackupFile -SourceFile $backupFile -DestinationFile $compressedFile) {
                $script:successCount++
                Write-Log "✔ Database '$dbName' backed up and compressed successfully" "SUCCESS"
            }
            else {
                throw "Compression failed for $dbName"
            }
        }
        catch {
            $script:failCount++
            $script:failedDatabases += "$dbName - $($_.Exception.Message)"
            Write-Log "✘ FAILED: $dbName - Error: $($_.Exception.Message)" "ERROR"
            
            # Clean up partial files
            if (Test-Path $backupFile) { Remove-Item $backupFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $compressedFile) { Remove-Item $compressedFile -Force -ErrorAction SilentlyContinue }
        }
    }
    
    # Final summary
    $totalDuration = (Get-Date) - $script:backupStartTime
    Write-Log "==================================================" "INFO"
    Write-Log "BACKUP PROCESS COMPLETED" "INFO"
    Write-Log "Total Duration: $($totalDuration.ToString('hh\:mm\:ss'))" "INFO"
    Write-Log "Successful: $script:successCount | Failed: $script:failCount" "INFO"
    Write-Log "==================================================" "INFO"
    
    # Send email if there were failures
    if ($script:failCount -gt 0) {
        Send-FailureEmail
    }
    
    exit $script:failCount
}
catch {
    Write-Log "CRITICAL ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "ERROR"
    Send-FailureEmail -CustomMessage $_.Exception.Message
    exit 99
}
finally {
    Write-Log "Log file saved to: $logFile" "INFO"
}