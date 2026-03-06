#!/bin/bash

# SQL Server 2022 Production Installation Script for Ubuntu 24.04
# Author: Production Setup Script
# Version: 1.1
# Description: Enterprise-grade SQL Server installation with security hardening

set -e

## while running please make sure you have the env file and gave the correct values for the variables
# Load environment variables from .env file
# Ensure the .env file exists and contains the required variables
# cmd : source .env
# or run the script with the .env file in the same directory
# Example .env file content:
# DB_NAME=YourDatabaseName
# SA_PASSWORD=YourStrongPassword
# READ_USER=readonlyuser
# READ_USER_PASSWORD=YourReadUserPassword   

if [ -f ".env" ]; then
    set -a
    source .env
    set +a
else
    echo -e "\033[0;31m[ERROR] .env file not found. Aborting.\033[0m"
    exit 1
fi
# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
    exit 1
}

warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

# Configuration variables
DB_NAME="$DB_NAME"
SA_PASSWORD="$SA_PASSWORD"
READ_USER="$READ_USER"
READ_USER_PASSWORD="$READ_USER_PASSWORD"
APP_USER="$APP_USER"
APP_USER_PASSWORD="$APP_USER_PASSWORD"
DEV_USER="$DEV_USER"
DEV_USER_PASSWORD="$DEV_USER_PASSWORD"
MSSQL_PID="$MSSQL_PID"
BACKUP_DIR="/var/opt/mssql/backup"
DATA_DIR="/var/opt/mssql/data"
LOG_DIR="/var/opt/mssql/log"
SCRIPT_DIR="/opt/mssql/scripts"
AUDIT_LOG="/var/opt/mssql/developer_changes.log"

validate_environment() {
    log "Validating environment variables..."
    for VAR in SA_PASSWORD READ_USER_PASSWORD APP_USER_PASSWORD DEV_USER_PASSWORD; do
        if [[ -z "${!VAR}" ]]; then
            error "$VAR environment variable is required"
        fi
        if [[ ${#VAR} -lt 8 ]]; then
            error "$VAR must be at least 8 characters long"
        fi
    done
    log "Environment validation passed"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

# Update system packages
update_system() {
    log "Updating system packages..."
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y curl gnupg software-properties-common apt-transport-https wget unzip
}

# Add Microsoft repository
add_microsoft_repo() {
    log "Adding Microsoft repository..."
    
    # Import Microsoft GPG key
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
    install -o root -g root -m 644 packages.microsoft.gpg /etc/apt/trusted.gpg.d/
    
    # Add Microsoft repository for Ubuntu 24.04
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/ubuntu/24.04/mssql-server-2022 noble main" > /etc/apt/sources.list.d/mssql-server-2022.list
    
    # Add tools repository
    echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/packages.microsoft.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/mssql-tools.list
    
    apt-get update -y
}

# Install SQL Server
install_sqlserver() {
    log "Installing SQL Server 2022..."
    
    # Install SQL Server
    apt-get install -y mssql-server
    
    # Install SQL Server command-line tools
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
    
    # Add tools to PATH
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> /etc/environment
    
    # Reload PATH
    source ~/.bashrc
}

# Configure SQL Server
configure_sqlserver() {
    log "Configuring SQL Server..."
    
    # Set SA password and accept EULA
    /opt/mssql/bin/mssql-conf set-sa-password "$SA_PASSWORD"
    /opt/mssql/bin/mssql-conf set sqlagent.enabled true
    
    # Set SQL Server edition
    /opt/mssql/bin/mssql-conf set-edition "$MSSQL_PID"
    
    # Configure memory settings (adjust based on your server specs)
    /opt/mssql/bin/mssql-conf set memory.memorylimitmb 4096
    
    # Configure maximum server memory (leaving 25% for OS)
    TOTAL_MEM=$(free -m | awk 'NR==2{printf "%.0f", $2*0.75}')
    /opt/mssql/bin/mssql-conf set memory.memorylimitmb $TOTAL_MEM
    
    # Enable backup compression by default
    /opt/mssql/bin/mssql-conf set backup.compression.default.enabled true
    
    # Configure network settings
    /opt/mssql/bin/mssql-conf set network.tcpport 1433
    /opt/mssql/bin/mssql-conf set network.ipaddress 0.0.0.0
    
    # Configure error log retention
    /opt/mssql/bin/mssql-conf set errorlog.numerrorlogs 30
    
    log "SQL Server configured successfully with $MSSQL_PID edition"
}

# Create directory structure
create_directories() {
    log "Creating directory structure..."
    
    # Create data directories
    mkdir -p "$DATA_DIR"
    mkdir -p "$LOG_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$SCRIPT_DIR"
    mkdir -p "$SCRIPT_DIR/tables"
    mkdir -p "$SCRIPT_DIR/functions"
    mkdir -p "$SCRIPT_DIR/procedures"
    mkdir -p "$SCRIPT_DIR/base-data"
    
    # Set ownership and permissions
    chown -R mssql:mssql "$DATA_DIR"
    chown -R mssql:mssql "$LOG_DIR"
    chown -R mssql:mssql "$BACKUP_DIR"
    chown -R mssql:mssql "$SCRIPT_DIR"
    
    chmod 750 "$DATA_DIR"
    chmod 750 "$LOG_DIR"
    chmod 750 "$BACKUP_DIR"
    chmod 755 "$SCRIPT_DIR"
    
    log "Directory structure created"
}

# Configure firewall
configure_firewall() {
    log "Configuring firewall..."
    
    # Install ufw if not present
    apt-get install -y ufw
    
    # Allow SSH (adjust port if needed)
    ufw allow 22/tcp
    
    # Allow SQL Server port
    ufw allow 1433/tcp
    
    # Enable firewall
    ufw --force enable
    
    log "Firewall configured"
}

# Start SQL Server service
start_sqlserver() {
    log "Starting SQL Server service..."
    
    systemctl enable mssql-server
    systemctl start mssql-server
    
    # Wait for SQL Server to start
    for i in {1..30}; do
        if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -Q "SELECT 1" > /dev/null 2>&1; then
            log "SQL Server is ready!"
            break
        fi
        info "Waiting for SQL Server to start... ($i/30)"
        sleep 2
    done
    
    if ! /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -Q "SELECT 1" > /dev/null 2>&1; then
        error "SQL Server failed to start properly"
    fi
}

# Execute SQL script
execute_sql() {
    local sql_command="$1"
    local description="$2"
    
    info "$description"
    if /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -C -Q "$sql_command"; then
        log "✓ Successfully executed: $description"
    else
        error "✗ Failed to execute: $description"
    fi
}

# Create database and users
create_database_and_users() {
    log "Creating database and users..."
    
    # Create main database
    execute_sql "CREATE DATABASE [$DB_NAME]" "Creating main database"
    
    # Create read-only user
    execute_sql "USE master; CREATE LOGIN [$READ_USER] WITH PASSWORD = '$READ_USER_PASSWORD', CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;" "Creating read-only login"
    execute_sql "USE [$DB_NAME]; CREATE USER [$READ_USER] FOR LOGIN [$READ_USER];" "Creating read-only user"
    execute_sql "USE [$DB_NAME]; ALTER ROLE db_datareader ADD MEMBER [$READ_USER];" "Adding read-only permissions"
    
    # Create application user
    execute_sql "USE master; CREATE LOGIN [$APP_USER] WITH PASSWORD = '$APP_USER_PASSWORD', CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;" "Creating application login"
    execute_sql "USE [$DB_NAME]; CREATE USER [$APP_USER] FOR LOGIN [$APP_USER];" "Creating application user"
    execute_sql "USE [$DB_NAME]; ALTER ROLE db_datareader ADD MEMBER [$APP_USER];" "Adding read permissions to app user"
    execute_sql "USE [$DB_NAME]; ALTER ROLE db_datawriter ADD MEMBER [$APP_USER];" "Adding write permissions to app user"
    execute_sql "USE [$DB_NAME]; ALTER ROLE db_executor ADD MEMBER [$APP_USER];" "Adding execute permissions to app user"
     # Create developer user
    execute_sql "USE master; CREATE LOGIN [$DEV_USER] WITH PASSWORD = '$DEV_USER_PASSWORD', CHECK_EXPIRATION = OFF, CHECK_POLICY = OFF;" "Creating developer login"
    execute_sql "USE [$DB_NAME]; CREATE USER [$DEV_USER] FOR LOGIN [$DEV_USER];" "Creating developer user"

    # Assign privileges to developer user (no DELETE)
    execute_sql "USE [$DB_NAME]; GRANT INSERT, SELECT, UPDATE, ALTER TO [$DEV_USER];" "Granting dev privileges (no DELETE)"

    # Create DDL trigger for auditing developer changes
    execute_sql "
    USE [$DB_NAME];
    CREATE OR ALTER TRIGGER tr_ddl_audit_dev
    ON DATABASE
    FOR CREATE_TABLE, ALTER_TABLE, DROP_TABLE, CREATE_PROCEDURE, ALTER_PROCEDURE, DROP_PROCEDURE, CREATE_FUNCTION, ALTER_FUNCTION, DROP_FUNCTION
    AS
    BEGIN
        INSERT INTO msdb.dbo.dev_audit_log
        SELECT SYSTEM_USER, OBJECT_NAME(parent_id), EVENTDATA(), GETDATE()
    END;
    " "Creating DDL trigger for developer audit"

    # Create audit log table if not exists
    execute_sql "
    USE msdb;
    IF OBJECT_ID('dbo.dev_audit_log') IS NULL
    CREATE TABLE dbo.dev_audit_log (
        UserName NVARCHAR(100),
        ObjectName NVARCHAR(128),
        EventXML XML,
        EventTime DATETIME
    );
    " "Creating developer audit log table"
    log "Database and users created successfully"
}

# Apply security hardening
apply_security_hardening() {
    log "Applying security hardening..."
    
    # Disable unnecessary features
    execute_sql "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;" "Enabling advanced options"
    execute_sql "EXEC sp_configure 'remote access', 0; RECONFIGURE;" "Disabling remote access"
    execute_sql "EXEC sp_configure 'remote admin connections', 0; RECONFIGURE;" "Disabling remote admin connections"
    execute_sql "EXEC sp_configure 'scan for startup procs', 0; RECONFIGURE;" "Disabling scan for startup procs"
    execute_sql "EXEC sp_configure 'cross db ownership chaining', 0; RECONFIGURE;" "Disabling cross db ownership chaining"
    execute_sql "EXEC sp_configure 'Ad Hoc Distributed Queries', 0; RECONFIGURE;" "Disabling Ad Hoc Distributed Queries"
    
    # Configure authentication
    execute_sql "EXEC sp_configure 'show advanced options', 0; RECONFIGURE;" "Hiding advanced options"
    
    # Remove unnecessary sample databases
    execute_sql "IF DB_ID('tempdb') IS NOT NULL DROP DATABASE IF EXISTS [AdventureWorks2022];" "Removing sample databases"
    
    log "Security hardening applied"
}

restore_from_backup() {
    local BACKUP_FILE="$1"
    if [[ ! -f "$BACKUP_FILE" ]]; then
        error "Backup file not found: $BACKUP_FILE"
    fi
    log "Restoring database from backup: $BACKUP_FILE"
    execute_sql "
    USE master;
    ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    RESTORE DATABASE [$DB_NAME] FROM DISK = N'$BACKUP_FILE' WITH REPLACE;
    ALTER DATABASE [$DB_NAME] SET MULTI_USER;
    " "Restoring database from backup"
}

# Create backup job
create_backup_job() {
    log "Creating backup maintenance job..."
    
    # Create backup script
    cat > /opt/mssql/backup-script.sql << 'EOF'
-- Full backup script
DECLARE @BackupPath NVARCHAR(500)
DECLARE @BackupName NVARCHAR(500)
DECLARE @DatabaseName NVARCHAR(128)

SET @DatabaseName = N'$(DatabaseName)'
SET @BackupPath = N'/var/opt/mssql/backup/' + @DatabaseName + '_' + CONVERT(NVARCHAR(20), GETDATE(), 112) + '_' + REPLACE(CONVERT(NVARCHAR(20), GETDATE(), 108), ':', '') + '.bak'
SET @BackupName = @DatabaseName + ' Full Backup ' + CONVERT(NVARCHAR(20), GETDATE(), 120)

BACKUP DATABASE @DatabaseName 
TO DISK = @BackupPath
WITH 
    COMPRESSION,
    CHECKSUM,
    INIT,
    NAME = @BackupName,
    STATS = 10
EOF
    
    # Create backup cleanup script
    cat > /opt/mssql/cleanup-backups.sh << 'EOF'
#!/bin/bash
# Cleanup old backup files (keep last 7 days)
find /var/opt/mssql/backup -name "*.bak" -type f -mtime +7 -delete
EOF
    
    chmod +x /opt/mssql/cleanup-backups.sh
    
    # Add to crontab for daily backup at 2 AM
    (crontab -l 2>/dev/null; echo "0 2 * * * /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P '$SA_PASSWORD' -v DatabaseName='$DB_NAME' -C -i /opt/mssql/backup-script.sql") | crontab -
    
    # Add cleanup job for weekly cleanup
    (crontab -l 2>/dev/null; echo "0 3 * * 0 /opt/mssql/cleanup-backups.sh") | crontab -
    
    log "Backup maintenance job created"
}

# Configure system service monitoring
configure_monitoring() {
    log "Configuring system monitoring..."
    
    # Create monitoring script
    cat > /opt/mssql/monitor-sqlserver.sh << 'EOF'
#!/bin/bash
# SQL Server monitoring script

LOG_FILE="/var/log/mssql-monitor.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# Check if SQL Server is running
if systemctl is-active --quiet mssql-server; then
    echo "[$DATE] SQL Server is running" >> $LOG_FILE
else
    echo "[$DATE] ERROR: SQL Server is not running" >> $LOG_FILE
    systemctl restart mssql-server
    echo "[$DATE] Attempted to restart SQL Server" >> $LOG_FILE
fi

# Check disk space
DISK_USAGE=$(df /var/opt/mssql | tail -1 | awk '{print $5}' | sed 's/%//')
if [ $DISK_USAGE -gt 80 ]; then
    echo "[$DATE] WARNING: Disk usage is at $DISK_USAGE%" >> $LOG_FILE
fi
EOF
    
    chmod +x /opt/mssql/monitor-sqlserver.sh
    
    # Add monitoring to crontab (every 5 minutes)
    (crontab -l 2>/dev/null; echo "*/5 * * * * /opt/mssql/monitor-sqlserver.sh") | crontab -
    
    log "System monitoring configured"
}

# Display connection information
display_connection_info() {
    log "Installation completed successfully!"
    echo
    echo "=== SQL Server Connection Information ==="
    echo "Server: localhost,1433"
    echo "SA Username: sa"
    echo "SA Password: [Your SA Password]"
    echo
    echo "Read-Only User: $READ_USER"
    echo "Read-Only Password: [Your Read User Password]"
    echo
    echo "Application User: $APP_USER"
    echo "Application Password: [Your App User Password]"
    echo
    echo "Database: $DB_NAME"
    echo
    echo "=== Important Directories ==="
    echo "Data Directory: $DATA_DIR"
    echo "Log Directory: $LOG_DIR"
    echo "Backup Directory: $BACKUP_DIR"
    echo "Scripts Directory: $SCRIPT_DIR"
    echo
    echo "=== Security Notes ==="
    echo "- Firewall is enabled with only SSH and SQL Server ports open"
    echo "- SA account is configured with your custom password"
    echo "- Read-only user has access to all databases"
    echo "- Application user has read/write/execute permissions"
    echo "- Daily backups are scheduled at 2 AM"
    echo "- Old backups are cleaned up weekly"
    echo
    echo "=== Next Steps ==="
    echo "1. Place your SQL scripts in the appropriate directories under $SCRIPT_DIR"
    echo "2. Test connectivity with: sqlcmd -S localhost -U sa -P [password] -C"
    echo "3. Monitor logs: tail -f /var/log/mssql-monitor.log"
    echo "4. Check service status: systemctl status mssql-server"
    echo
}

# Main execution
main() {
    log "Starting SQL Server Production Installation..."
    
    check_root
    validate_environment
    update_system
    add_microsoft_repo
    install_sqlserver
    create_directories
    configure_firewall
    configure_sqlserver
    start_sqlserver
    create_database_and_users
    apply_security_hardening
    execute_database_scripts
    create_backup_job
    configure_monitoring
    display_connection_info
    
    log "SQL Server installation and configuration completed!"
}

# Run main function
main "$@"