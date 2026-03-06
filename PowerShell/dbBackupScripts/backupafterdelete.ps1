# =====================================================
# SQL Server Backup Script - IMPROVED VERSION
# =====================================================

# Variables
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


#Delete ALL existing files in backup folder

Remove-Item "$backupDirectory\*"-Recurse -Force


Write-Host "All old backup files deleted from $backupDirectory" -ForegroundColor Cyan

# Create backup directory if it doesn't exist
if (-not (Test-Path $backupDirectory)) {
    New-Item -Path $backupDirectory -ItemType Directory | Out-Null
}

# Load SQL Server module
Import-Module SqlServer -ErrorAction Stop

# Define a secure connection string (bypass SSL error)
$connectionString = "Server=$serverInstance;TrustServerCertificate=True;Integrated Security=True"

# Get list of user databases
$databases = Invoke-Sqlcmd -ConnectionString $connectionString -Query "SELECT name FROM sys.databases WHERE name NOT IN ('master','model','msdb','tempdb')"

foreach ($db in $databases) {
    $dbName = $db.name
    $backupFile = Join-Path -Path $backupDirectory -ChildPath "$($dbName)_FullBackup_$dateStamp.bak"

    Write-Host "Backing up database: $dbName"

    try {
        # Compression removed for Web Edition compatibility
        $sqlBackupQuery = "BACKUP DATABASE [$dbName] TO DISK = N'$backupFile' WITH INIT"
        Invoke-Sqlcmd -ConnectionString $connectionString -Query $sqlBackupQuery
        Write-Host "✔ Backup completed for: $dbName" -ForegroundColor Green
    }
    catch {
        Write-Host "✘ Backup failed for $dbName. Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}


# =====================================================
# EMAIL NOTIFICATION (ONLY ON FAILURE)
# =====================================================
if ($enableEmailAlerts -and $failCount -gt 0) {
    $subject = "⚠️ SQL Backup Alert - $failCount Failure(s) on $serverInstance"
    $body = @"
SQL Server Backup Report

Server: $serverInstance
Date: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Total Databases: $($databases.Rows.Count)
Successful: $successCount
Failed: $failCount

Failed Databases:
$($failedDatabases -join "`n")

Please investigate immediately.
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
            -Priority High `
            -ErrorAction Stop
        
        Write-Log "Alert email sent to $emailTo" "SUCCESS"
    }
    catch {
        Write-Log "Failed to send email notification: $($_)" "WARNING"
    }
}

# Exit with error code
exit $failCount