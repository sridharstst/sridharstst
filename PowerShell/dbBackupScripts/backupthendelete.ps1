# =====================================================
# SQL Server Backup Script - Production Ready
# Retention: Keeps only 1 backup per database
# Strategy: Backup-Then-Delete (Safe)
# =====================================================

# Variables
$serverInstance = "StandardDb"
$backupDirectory = "G:\Backup"
$dateStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$retentionDays = 1  # Keep only today's backup

# Email notification settings (optional)
$enableEmailAlerts = $false
$smtpServer = "smtp.gmail.com"
$smtpPort = "587"
$emailFrom = ""
$emailTo = ""
$emailUsername = ""
$emailPassword = ""

# =====================================================
# LOGGING FUNCTION
# =====================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    $color = switch($Level) {
        "ERROR" { "Red" }
        "SUCCESS" { "Green" }
        "WARNING" { "Yellow" }
        default { "White" }
    }
    
    Write-Host $logMessage -ForegroundColor $color
    
    # Optional: Write to log file
    # $logFile = Join-Path $backupDirectory "BackupLog_$(Get-Date -Format 'yyyyMMdd').log"
    # $logMessage | Out-File -FilePath $logFile -Append
}

# =====================================================
# CREATE BACKUP DIRECTORY
# =====================================================
if (-not (Test-Path $backupDirectory)) {
    New-Item -Path $backupDirectory -ItemType Directory | Out-Null
    Write-Log "Created backup directory: $backupDirectory" "SUCCESS"
}

# =====================================================
# LOAD SQL SERVER MODULE
# =====================================================
try {
    Import-Module SqlServer -ErrorAction Stop
    Write-Log "SQL Server module loaded successfully" "SUCCESS"
}
catch {
    Write-Log "Failed to load SQL Server module: $($_.Exception.Message)" "ERROR"
    exit 1
}

# =====================================================
# ESTABLISH SQL CONNECTION
# =====================================================
$connectionString = "Server=$serverInstance;TrustServerCertificate=True;Integrated Security=True;Connection Timeout=30"

try {
    $testQuery = "SELECT @@VERSION"
    $null = Invoke-Sqlcmd -ConnectionString $connectionString -Query $testQuery -ErrorAction Stop
    Write-Log "Connected to SQL Server: $serverInstance" "SUCCESS"
}
catch {
    Write-Log "Cannot connect to SQL Server: $($_.Exception.Message)" "ERROR"
    exit 1
}

# =====================================================
# GET USER DATABASES (EXCLUDE SYSTEM DATABASES)
# =====================================================
$databaseQuery = @"
SELECT name 
FROM sys.databases 
WHERE name NOT IN ('master', 'model', 'msdb', 'tempdb')
  AND state_desc = 'ONLINE'
ORDER BY name
"@

try {
    $databases = Invoke-Sqlcmd -ConnectionString $connectionString -Query $databaseQuery
    Write-Log "Found $($databases.Count) user database(s) to backup" "INFO"
}
catch {
    Write-Log "Failed to retrieve database list: $($_.Exception.Message)" "ERROR"
    exit 1
}

$drive = (Get-Item $backupDirectory).PSDrive.Name
$freeSpace = (Get-PSDrive $drive).Free / 1GB
if ($freeSpace -lt 50) {
    Write-Log "WARNING: Low disk space on ${drive}: $([math]::Round($freeSpace, 2)) GB" "WARNING"
}

# =====================================================
# BACKUP PROCESS
# =====================================================
$successCount = 0
$failCount = 0
$failedDatabases = @()

foreach ($db in $databases) {
    $dbName = $db.name
    $backupFile = Join-Path -Path $backupDirectory -ChildPath "$($dbName)_FullBackup_$dateStamp.bak"
    
    Write-Log "Starting backup: $dbName" "INFO"
    
    try {
        # Perform full database backup (no compression for Web Edition)
        $sqlBackupQuery = @"
BACKUP DATABASE [$dbName] 
TO DISK = N'$backupFile' 
WITH INIT, 
     FORMAT, 
     NAME = N'$dbName-Full Database Backup', 
     STATS = 10,
     CHECKSUM
"@
        
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $sqlBackupQuery -QueryTimeout 3600
        
        # Verify backup file exists and has size > 0
        if (Test-Path $backupFile) {
            $fileSize = (Get-Item $backupFile).Length / 1MB
            Write-Log "✔ Backup completed: $dbName (Size: $([math]::Round($fileSize, 2)) MB)" "SUCCESS"
            $successCount++
            
            # =====================================================
            # DELETE OLD BACKUPS (ONLY AFTER SUCCESSFUL BACKUP)
            # =====================================================
            $pattern = "$($dbName)_FullBackup_*.bak"
            $oldBackups = Get-ChildItem -Path $backupDirectory -Filter $pattern | 
                          Where-Object { $_.Name -ne (Split-Path $backupFile -Leaf) } |
                          Sort-Object LastWriteTime -Descending
            
            if ($oldBackups) {
                foreach ($oldFile in $oldBackups) {
                    try {
                        Remove-Item $oldFile.FullName -Force
                        Write-Log "Deleted old backup: $($oldFile.Name)" "INFO"
                    }
                    catch {
                        Write-Log "Warning: Could not delete $($oldFile.Name): $($_.Exception.Message)" "WARNING"
                    }
                }
            }
        }
        else {
            throw "Backup file was not created"
        }
    }
    catch {
        Write-Log "✘ Backup failed: $dbName - Error: $($_.Exception.Message)" "ERROR"
        $failCount++
        $failedDatabases += $dbName
    }
}

# =====================================================
# FINAL REPORT
# =====================================================
Write-Log "========================================" "INFO"
Write-Log "BACKUP SUMMARY" "INFO"
Write-Log "Total Databases: $($databases.Count)" "INFO"
Write-Log "Successful: $successCount" "SUCCESS"
Write-Log "Failed: $failCount" $(if ($failCount -gt 0) { "ERROR" } else { "INFO" })

if ($failedDatabases.Count -gt 0) {
    Write-Log "Failed databases: $($failedDatabases -join ', ')" "ERROR"
}

Write-Log "========================================" "INFO"

# =====================================================
# EMAIL NOTIFICATION (OPTIONAL)
# =====================================================
if ($enableEmailAlerts -and $failCount -gt 0) {
    $subject = "SQL Backup Alert - $failCount Failure(s) on $serverInstance"
    $body = @"
SQL Server Backup Report
Server: $serverInstance
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Total Databases: $($databases.Count)
Successful: $successCount
Failed: $failCount

Failed Databases:
$($failedDatabases -join "`n")
"@
    
    try {
        # Create credential object for Gmail authentication
        $securePassword = ConvertTo-SecureString $emailPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($emailUsername, $securePassword)
        
        # Send email with Gmail-specific settings
        Send-MailMessage `
            -SmtpServer $smtpServer `
            -Port $smtpPort `
            -UseSsl `
            -Credential $credential `
            -From $emailFrom `
            -To $emailTo `
            -Subject $subject `
            -Body $body `
            -ErrorAction Stop
        
        Write-Log "Email notification sent successfully to $emailTo" "SUCCESS"
    }
    catch {
        Write-Log "Failed to send email notification: $($_.Exception.Message)" "WARNING"
    }
}


# Exit with error code if any backups failed
exit $failCount