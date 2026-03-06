#!/bin/bash
set -e

# Color codes for better logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${BLUE}[$timestamp] INFO:${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] SUCCESS:${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[$timestamp] WARNING:${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[$timestamp] ERROR:${NC} $message"
            ;;
    esac
}

# Function to prevent restart loops
create_failure_marker() {
    local script_name=$1
    local error_msg=$2
    echo "FAILED: $script_name - $error_msg - $(date)" >> /var/opt/mssql/data/.failed_scripts
}

check_failure_marker() {
    local script_name=$1
    if [[ -f "/var/opt/mssql/data/.failed_scripts" ]]; then
        if grep -q "$script_name" /var/opt/mssql/data/.failed_scripts; then
            return 0  # Script has failed before
        fi
    fi
    return 1  # Script hasn't failed before
}

# Enhanced SQL Server startup with better resource management
start_sql_server() {
    log "INFO" "Configuring SQL Server startup parameters..."
    
    # Create custom startup configuration
    cat > /var/opt/mssql/mssql.conf << EOF
[EULA]
accepteula = Y

[coredump]
captureminiandfull = true
coredumptype = full

[filelocation]
defaultbackupdir = /var/opt/mssql/backup
defaultdatadir = /var/opt/mssql/data
defaultlogdir = /var/opt/mssql/log

[memory]
memorylimitmb = ${MSSQL_MEMORY_LIMIT_MB:-4096}

[sqlagent]
enabled = ${MSSQL_AGENT_ENABLED:-false}

[traceflag]
# Enable instant file initialization
traceflag0 = 1117
# Reduce lock escalation
traceflag1 = 1211
# Reduce allocation contention
traceflag2 = 1118
EOF

    # Set proper ownership
    chown mssql:root /var/opt/mssql/mssql.conf
    chmod 600 /var/opt/mssql/mssql.conf
    
    log "INFO" "Starting SQL Server with enhanced configuration..."
    /opt/mssql/bin/sqlservr &
    SERVER_PID=$!
    
    # Give SQL Server more time to initialize
    sleep 15
}

# Enhanced wait for SQL Server with progressive timeout
wait_for_sql_server() {
    local max_attempts=120  # Increased from 60
    local attempt=1
    local base_delay=5
    
    log "INFO" "Waiting for SQL Server to be ready (up to 10 minutes)..."
    
    while [ $attempt -le $max_attempts ]; do
        # Progressive delay - start with shorter delays, increase over time
        local delay=$base_delay
        if [ $attempt -gt 30 ]; then
            delay=10
        fi
        
        # Check basic connectivity
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT 1" -t 30 > /dev/null 2>&1; then
            # Verify system is fully ready
            if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT @@VERSION" -t 30 > /dev/null 2>&1; then
                # Check if tempdb is accessible (critical for full functionality)
                if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "USE tempdb; SELECT 1" -t 30 > /dev/null 2>&1; then
                    log "SUCCESS" "SQL Server is fully ready and operational!"
                    # Additional stabilization time
                    sleep 10
                    return 0
                fi
            fi
        fi
        
        # Show progress every 10 attempts
        if (( attempt % 10 == 0 )); then
            log "INFO" "Still waiting for SQL Server... ($attempt/$max_attempts) - checking server logs"
            # Show recent error log entries if available
            if [[ -f "/var/opt/mssql/log/errorlog" ]]; then
                tail -5 /var/opt/mssql/log/errorlog 2>/dev/null | while read line; do
                    log "INFO" "ERRORLOG: $line"
                done
            fi
        else
            log "INFO" "SQL Server not ready yet, waiting... ($attempt/$max_attempts)"
        fi
        
        sleep $delay
        ((attempt++))
    done
    
    log "ERROR" "SQL Server failed to become ready within timeout (10 minutes)"
    
    # Show detailed error information
    log "ERROR" "Dumping recent error log entries:"
    if [[ -f "/var/opt/mssql/log/errorlog" ]]; then
        tail -20 /var/opt/mssql/log/errorlog 2>/dev/null | while read line; do
            log "ERROR" "ERRORLOG: $line"
        done
    fi
    
    return 1
}

# Check if database already exists
check_database_exists() {
    local db_name="${1:-$DB_NAME}"
    
    log "DEBUG" "Checking if database '$db_name' exists and is accessible..."
    
    # Check if database exists in metadata
    local db_exists
    if db_exists=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master -h-1 -W \
        -Q "SELECT COUNT(*) FROM sys.databases WHERE name = '$db_name'" -t 30 2>/dev/null | tr -d ' \n\r'); then
        
        if [[ "$db_exists" == "1" ]]; then
            log "DEBUG" "Database '$db_name' exists in SQL Server metadata"
            
            # Check if database is accessible
            if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$db_name" \
                -Q "SELECT 1;" -t 30 >/dev/null 2>&1; then
                log "DEBUG" "Database '$db_name' is accessible"
                echo "1"  # Database exists and is accessible
            else
                log "WARNING" "Database '$db_name' exists but is not accessible (corrupted)"
                echo "2"  # Database exists but is corrupted
            fi
        else
            log "DEBUG" "Database '$db_name' does not exist"
            echo "0"  # Database does not exist
        fi
    else
        log "ERROR" "Cannot connect to SQL Server to check database"
        echo "-1"  # Cannot determine
    fi
}

# Enhanced database accessibility check with recovery state monitoring
wait_for_database_access() {
    local max_attempts=60  # Increased timeout
    local attempt=1
    
    log "INFO" "Waiting for database '$DB_NAME' to be accessible..."
    
    while [ $attempt -le $max_attempts ]; do
        # Check if database exists first
        local db_exists=$(check_database_exists)
        if [[ "$db_exists" != "1" ]]; then
            log "ERROR" "Database '$DB_NAME' does not exist"
            return 1
        fi
        
        # Check database state and recovery model
        local db_info=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -h -1 -W -s"|" -Q "
            SELECT 
                state_desc,
                recovery_model_desc,
                is_in_standby,
                CASE WHEN EXISTS(SELECT 1 FROM sys.dm_exec_requests WHERE database_id = DB_ID('$DB_NAME') AND command IN ('RESTORE DATABASE','BACKUP DATABASE')) 
                     THEN 'RESTORE_ACTIVE' 
                     ELSE 'NO_RESTORE' 
                END as restore_status
            FROM sys.databases 
            WHERE name = '$DB_NAME'
        " -t 30 2>/dev/null)
        
        if [[ -n "$db_info" ]]; then
            local state=$(echo "$db_info" | awk -F'|' '{print $1}' | tr -d ' ')
            local recovery_model=$(echo "$db_info" | awk -F'|' '{print $2}' | tr -d ' ')
            local in_standby=$(echo "$db_info" | awk -F'|' '{print $3}' | tr -d ' ')
            local restore_status=$(echo "$db_info" | awk -F'|' '{print $4}' | tr -d ' ')
            
            log "INFO" "Database state: $state, Recovery: $recovery_model, Standby: $in_standby, Restore: $restore_status"
            
            # Check for ONLINE state and no active restore
            if [[ "$state" == "ONLINE" && "$restore_status" != "RESTORE_ACTIVE" ]]; then
                # Final connectivity test
                if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$DB_NAME" -Q "SELECT 1" -t 30 > /dev/null 2>&1; then
                    log "SUCCESS" "Database '$DB_NAME' is accessible and online"
                    return 0
                fi
            elif [[ "$state" == "RESTORING" || "$restore_status" == "RESTORE_ACTIVE" ]]; then
                log "INFO" "Database is still being restored, waiting..."
            elif [[ "$state" == "RECOVERING" ]]; then
                log "INFO" "Database is in recovery mode, waiting..."
            else
                log "WARNING" "Database in unexpected state: $state"
            fi
        fi
        
        # Show progress every 10 attempts
        if (( attempt % 10 == 0 )); then
            log "INFO" "Still waiting for database access... ($attempt/$max_attempts)"
            # Check for blocking processes
            /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
                SELECT 
                    'BLOCKING_INFO' as info_type,
                    session_id, 
                    status, 
                    blocking_session_id, 
                    wait_type,
                    wait_time,
                    command
                FROM sys.dm_exec_requests 
                WHERE database_id = DB_ID('$DB_NAME') OR blocking_session_id > 0
            " -t 30 2>/dev/null | while read line; do
                if [[ "$line" == *"BLOCKING_INFO"* ]]; then
                    log "WARNING" "Active process: $line"
                fi
            done
        fi
        
        sleep 5
        ((attempt++))
    done
    
    log "ERROR" "Database '$DB_NAME' failed to become accessible within timeout"
    
    # Final diagnostic information
    log "ERROR" "Final database state check:"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
        SELECT name, state_desc, recovery_model_desc 
        FROM sys.databases 
        WHERE name = '$DB_NAME'
    " -t 30 2>/dev/null | while read line; do
        log "ERROR" "DB_STATE: $line"
    done
    
    return 1
}

# Enhanced backup file search
get_backup_path() {
    local candidates=()
    
    log "INFO" "Searching for backup files..." >&2
    
    # Debug information about available backup locations - redirect to stderr
    for backup_dir in "/var/opt/mssql/backup/host" "/var/opt/mssql/backup"; do
        if [[ -d "$backup_dir" ]]; then
            log "INFO" "Backup directory '$backup_dir' contents:" >&2
            ls -la "$backup_dir" 2>/dev/null | head -10 | while read line; do
                log "INFO" "  $line" >&2
            done
        else
            log "WARNING" "Backup directory '$backup_dir' not found" >&2
        fi
    done
    
    # Prefer explicit file name
    if [[ -n "${DB_BACKUP_FILE}" ]]; then
        candidates+=("/var/opt/mssql/backup/host/${DB_BACKUP_FILE}")
        candidates+=("/var/opt/mssql/backup/${DB_BACKUP_FILE}")
    fi
    
    # Try database name variations
    candidates+=("/var/opt/mssql/backup/host/${DB_NAME}.bak")
    candidates+=("/var/opt/mssql/backup/${DB_NAME}.bak")
    
    # Try common patterns
    candidates+=("/var/opt/mssql/backup/host/${DB_NAME}_*.bak")
    candidates+=("/var/opt/mssql/backup/${DB_NAME}_*.bak")
    
    # Fallback to any .bak file (newest first)
    local fallback_files=($(find /var/opt/mssql/backup -name "*.bak" -type f -exec ls -t {} + 2>/dev/null))
    for file in "${fallback_files[@]}"; do
        candidates+=("$file")
    done
    
    log "INFO" "Checking backup candidates: ${#candidates[@]} files" >&2
    
    for backup_path in "${candidates[@]}"; do
        if [[ -f "$backup_path" && -r "$backup_path" ]]; then
            local file_size=$(stat -c%s "$backup_path" 2>/dev/null || echo "0")
            if [[ "$file_size" -gt "10000" ]]; then  # Minimum 10KB
                log "SUCCESS" "Found valid backup: $backup_path (${file_size} bytes)" >&2
                # ONLY output the path to stdout - this is what gets captured
                echo "$backup_path"
                return 0
            else
                log "WARNING" "Backup file too small: $backup_path (${file_size} bytes)" >&2
            fi
        fi
    done
    
    log "WARNING" "No valid backup file found" >&2
    return 1
}


verify_database_access() {
    log "INFO" "Verifying database access..."
    
    # Test basic connectivity
    if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "SELECT 'ACCESS_OK' as status, COUNT(*) as table_count FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'" -t 30 2>/dev/null | grep -q "ACCESS_OK"; then
        log "SUCCESS" "Database access verified successfully"
        return 0
    else
        log "ERROR" "Database access verification failed"
        
        # Additional diagnostic information
        log "INFO" "Running database diagnostics..."
        /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master -Q "
            SELECT 
                name,
                state_desc,
                user_access_desc,
                recovery_model_desc,
                is_in_standby
            FROM sys.databases 
            WHERE name = '$DB_NAME'
        " -t 30 2>/dev/null | while IFS= read -r line; do
            [[ -n "$line" ]] && log "INFO" "DB_DIAG: $line"
        done
        
        return 1
    fi
}

get_backup_logical_names() {
    local backup_path="$1"
    local sqlcmd_output
    local data_logical_name=""
    local log_logical_name=""
    
    # Log to stderr to avoid contaminating the output
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Retrieving logical file names from backup..." >&2
    
    # Execute sqlcmd and capture only the output, redirect errors to stderr
    sqlcmd_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -Q "RESTORE FILELISTONLY FROM DISK = N'$backup_path'" -W -s"|" -h-1 2>&2)
    
    local sqlcmd_exit_code=$?
    
    if [[ $sqlcmd_exit_code -ne 0 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to retrieve file list from backup (exit code: $sqlcmd_exit_code)" >&2
        return 1
    fi
    
    if [[ -z "$sqlcmd_output" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: No output received from RESTORE FILELISTONLY" >&2
        return 1
    fi
    
    # Parse the output line by line
    while IFS='|' read -r LogicalName PhysicalName Type FileGroupName Size MaxSize FileId CreateLSN DropLSN UniqueId ReadOnlyLSN ReadWriteLSN BackupSizeInBytes SourceBlockSize FileGroupId LogGroupGUID DifferentialBaseLSN DifferentialBaseGUID IsReadOnly IsPresent TDEThumbprint SnapshotURL; do
        # Clean up the fields by removing leading/trailing whitespace
        LogicalName=$(echo "$LogicalName" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        Type=$(echo "$Type" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Skip empty lines or header lines
        [[ -z "$LogicalName" || "$LogicalName" == "LogicalName" ]] && continue
        
        case "$Type" in
            D)
                if [[ -z "$data_logical_name" ]]; then
                    data_logical_name="$LogicalName"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Detected DATA logical name: '$data_logical_name'" >&2
                fi
                ;;
            L)
                if [[ -z "$log_logical_name" ]]; then
                    log_logical_name="$LogicalName"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Detected LOG logical name: '$log_logical_name'" >&2
                fi
                ;;
        esac
        
        # Break if we have both names
        [[ -n "$data_logical_name" && -n "$log_logical_name" ]] && break
        
    done <<< "$sqlcmd_output"
    
    if [[ -z "$data_logical_name" || -z "$log_logical_name" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to detect both data and log logical names" >&2
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: Raw sqlcmd output:" >&2
        echo "$sqlcmd_output" >&2
        return 1
    fi
    
    # Output only the logical names (to stdout)
    echo "$data_logical_name|$log_logical_name"
    return 0
}

# Verify backup file integrity
verify_backup_integrity() {
    local backup_path="$1"
    
    log "INFO" "Verifying backup file: $backup_path"
    
    # Validate input parameter
    if [[ -z "$backup_path" ]]; then
        log "ERROR" "No backup path provided to verify_backup_integrity function"
        return 1
    fi
    
    # Basic file checks
    if [[ ! -f "$backup_path" ]]; then
        log "ERROR" "Backup file does not exist: $backup_path"
        return 1
    fi
    
    if [[ ! -r "$backup_path" ]]; then
        log "ERROR" "Backup file is not readable: $backup_path"
        return 1
    fi
    
    local file_size=$(stat -c%s "$backup_path" 2>/dev/null || echo "0")
    log "INFO" "Backup file size: $file_size bytes"
    
    if [[ "$file_size" -lt 10000 ]]; then
        log "ERROR" "Backup file seems too small: $file_size bytes"
        return 1
    fi
    
    # Try SQL Server verification with more lenient approach
    log "INFO" "Running SQL Server backup verification..."
    local verify_output
    
    # First try to read the backup structure (most basic test)
    log "INFO" "Testing backup file readability with FILELISTONLY..."
    if verify_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -Q "RESTORE FILELISTONLY FROM DISK = N'$backup_path';" -t 180 2>&1); then
        
        if echo "$verify_output" | grep -qE "(LogicalName|physical_name)" || echo "$verify_output" | grep -q "rows affected"; then
            log "SUCCESS" "Backup structure is readable - backup appears valid"
            log "DEBUG" "FILELISTONLY output sample:"
            echo "$verify_output" | head -5 | while IFS= read -r line; do
                [[ -n "$line" ]] && log "DEBUG" "  $line"
            done
            return 0
        else
            log "WARNING" "FILELISTONLY returned unexpected output:"
            echo "$verify_output" | head -10 | while IFS= read -r line; do
                [[ -n "$line" ]] && log "WARNING" "  $line"
            done
        fi
    else
        log "ERROR" "Failed to read backup file structure:"
        echo "$verify_output" | head -10 | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line"
        done
    fi
    
    # Try without CHECKSUM (more lenient verification)
    log "INFO" "Attempting lenient backup verification..."
    if verify_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master \
        -Q "RESTORE VERIFYONLY FROM DISK = N'$backup_path';" -t 300 2>&1); then
        
        if echo "$verify_output" | grep -qiE "(successfully processed|backup set is valid|completed successfully)"; then
            log "SUCCESS" "Backup verification passed"
            return 0
        elif echo "$verify_output" | grep -qiE "(checksum|verification|error|failed|corrupt)"; then
            log "WARNING" "Backup verification issues detected:"
            echo "$verify_output" | grep -iE "(checksum|verification|error|failed|corrupt)" | head -5 | while IFS= read -r line; do
                [[ -n "$line" ]] && log "WARNING" "  $line"
            done
            log "WARNING" "Proceeding anyway - backup may still be restorable"
            return 0
        fi
    fi
    
    log "ERROR" "Backup file appears to be corrupted or incompatible"
    log "DEBUG" "Final verification output:"
    echo "$verify_output" | tail -10 | while IFS= read -r line; do
        [[ -n "$line" ]] && log "DEBUG" "  $line"
    done
    return 1
}

# Enhanced restore function with dynamic file name detection
restore_from_backup() {
    local backup_path="$1"
    
    # Validate input
    if [[ -z "$backup_path" ]]; then
        log "ERROR" "No backup path provided to restore_from_backup"
        return 1
    fi
    
    log "INFO" "Starting restore process from: $backup_path"
    
    # Basic file validation
    if [[ ! -f "$backup_path" ]]; then
        log "ERROR" "Backup file not found: $backup_path"
        return 1
    fi
    
    local file_size=$(stat -c%s "$backup_path" 2>/dev/null || echo "0")
    log "INFO" "Backup file size: $file_size bytes"
    
    if [[ "$file_size" -lt 10000 ]]; then
        log "ERROR" "Backup file too small: $file_size bytes"
        return 1
    fi
    
    # Get logical file names from backup
    local logical_names
    if ! logical_names=$(get_backup_logical_names "$backup_path"); then
        log "ERROR" "Failed to retrieve logical file names from backup"
        return 1
    fi
    
    local data_logical_name=$(echo "$logical_names" | cut -d'|' -f1)
    local log_logical_name=$(echo "$logical_names" | cut -d'|' -f2)
    
    log "INFO" "Using logical names - DATA: '$data_logical_name', LOG: '$log_logical_name'"
    
    # Validate logical names
    if [[ -z "$data_logical_name" || -z "$log_logical_name" ]]; then
        log "ERROR" "Invalid logical names - DATA: '$data_logical_name', LOG: '$log_logical_name'"
        return 1
    fi
    
    # Ensure target directories exist with proper permissions
    log "INFO" "Setting up target directories..."
    mkdir -p /var/opt/mssql/data /var/opt/mssql/log
    chown mssql:root /var/opt/mssql/data /var/opt/mssql/log
    chmod 755 /var/opt/mssql/data /var/opt/mssql/log
    
    # Define target file paths
    local target_data_file="/var/opt/mssql/data/${DB_NAME}.mdf"
    local target_log_file="/var/opt/mssql/log/${DB_NAME}_log.ldf"
    
    # Pre-restore cleanup
    log "INFO" "Performing pre-restore cleanup..."
    local cleanup_sql="
    IF DB_ID(N'$DB_NAME') IS NOT NULL
    BEGIN
        ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
        DROP DATABASE [$DB_NAME];
        PRINT 'Dropped existing database: $DB_NAME';
    END
    ELSE
    BEGIN
        PRINT 'Database $DB_NAME does not exist, no cleanup needed';
    END
    "
    
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master \
        -Q "$cleanup_sql" -t 60 2>/dev/null || true
    
    # Clean up any existing files
    log "INFO" "Removing any existing database files..."
    rm -f "$target_data_file" "$target_log_file" 2>/dev/null || true
    
    # Wait a moment for cleanup to complete
    sleep 5
    
    # Build restore command with proper escaping - using square brackets for SQL identifiers
    local restore_sql="
    SET NOCOUNT ON;
    PRINT 'Starting restore of database: $DB_NAME';
    PRINT 'Source backup file: $backup_path';
    PRINT 'Target DATA file: $target_data_file';
    PRINT 'Target LOG file: $target_log_file';
    PRINT 'DATA logical name: $data_logical_name';
    PRINT 'LOG logical name: $log_logical_name';
    
    RESTORE DATABASE [$DB_NAME]
    FROM DISK = N'${backup_path}'
    WITH 
        MOVE N'${data_logical_name}' TO N'${target_data_file}',
        MOVE N'${log_logical_name}' TO N'${target_log_file}',
        REPLACE,
        STATS = 10;
    
    -- Post-restore configuration
    ALTER DATABASE [$DB_NAME] SET COMPATIBILITY_LEVEL = 150;
    ALTER DATABASE [$DB_NAME] SET RECOVERY SIMPLE;
    ALTER DATABASE [$DB_NAME] SET MULTI_USER;
    
    PRINT 'Database restore completed successfully';
    SELECT 'RESTORE_SUCCESS' as RestoreStatus;
    "
    
    log "INFO" "Executing restore command (this may take several minutes for large databases)..."
    log "DEBUG" "Restore SQL being executed:"
    echo "$restore_sql" | while IFS= read -r line; do
        [[ -n "$line" ]] && log "DEBUG" "  $line"
    done
    
    local restore_output
    if restore_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d master -Q "$restore_sql" -t 1800 2>&1); then
        
        log "INFO" "Restore command executed, checking results..."
        
        # Show progress information
        echo "$restore_output" | grep -E "(percent|processed|RESTORE_SUCCESS)" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "INFO" "  $line"
        done
        
        if echo "$restore_output" | grep -q "RESTORE_SUCCESS"; then
            log "SUCCESS" "Database restore completed successfully!"
            
            # Verify database accessibility
            sleep 10
            if wait_for_database_access; then
                log "SUCCESS" "Database is accessible and ready for use"
                return 0
            else
                log "ERROR" "Database restored but not accessible"
                return 1
            fi
        else
            log "ERROR" "Restore command executed but success marker not found"
            log "ERROR" "Full restore output:"
            echo "$restore_output" | while IFS= read -r line; do
                [[ -n "$line" ]] && log "ERROR" "  $line"
            done
            return 1
        fi
    else
        log "ERROR" "Restore command failed"
        log "ERROR" "Error details:"
        echo "$restore_output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line"
        done
        return 1
    fi
}

# Enhanced restore logic with better error handling
restore_backup_if_needed() {
    log "INFO" "Checking if backup restore is needed..."
    
    # Check database status first
    local db_status=$(check_database_exists)
    log "DEBUG" "Database status check returned: '$db_status'"
    
    case $db_status in
        1)
            log "INFO" "Database '$DB_NAME' exists and is accessible. Skipping restore."
            log "INFO" "This is normal behavior - restore only happens on first run"
            return 0
            ;;
        0)
            log "INFO" "Database '$DB_NAME' does not exist. Attempting restore from backup..."
            ;;
        2)
            log "WARNING" "Database '$DB_NAME' exists but is corrupted/inaccessible. Attempting restore..."
            ;;
        -1)
            log "ERROR" "Cannot determine database status - SQL Server connection failed"
            return 1
            ;;
        *)
            log "WARNING" "Unknown database status: '$db_status'. Attempting restore anyway..."
            ;;
    esac
    
    # Get backup path with proper variable capture
    local backup_path
    backup_path=$(get_backup_path)
    local get_backup_result=$?
    
    log "DEBUG" "get_backup_path returned: exit_code=$get_backup_result, path='$backup_path'"
    
    if [[ $get_backup_result -ne 0 || -z "$backup_path" ]]; then
        log "INFO" "No backup file found. Will create fresh database if needed."
        return 1
    fi
    
    log "INFO" "Backup file found: $backup_path"
    
    # Verify backup file exists and is accessible
    if [[ ! -f "$backup_path" ]]; then
        log "ERROR" "Backup file not found at path: $backup_path"
        log "DEBUG" "Attempting to list directory contents around the expected path:"
        local backup_dir=$(dirname "$backup_path")
        if [[ -d "$backup_dir" ]]; then
            ls -la "$backup_dir" | while read line; do
                log "DEBUG" "  $line"
            done
        fi
        return 1
    fi
    
    # Attempt restore
    log "INFO" "Starting restore process..."
    if restore_from_backup "$backup_path"; then
        log "SUCCESS" "Database restore completed successfully"
        return 0
    else
        log "ERROR" "Backup restore failed"
        return 1
    fi
}

# Helper function to wait for database access
wait_for_database_access() {
    local max_wait=60
    local wait_time=0
    
    log "INFO" "Waiting for database '$DB_NAME' to become accessible..."
    
    while [[ $wait_time -lt $max_wait ]]; do
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
            -d "$DB_NAME" -Q "SELECT 1" -t 10 >/dev/null 2>&1; then
            log "SUCCESS" "Database '$DB_NAME' is accessible"
            return 0
        fi
        
        sleep 5
        wait_time=$((wait_time + 5))
        log "INFO" "Waiting for database access... ($wait_time/$max_wait seconds)"
    done
    
    log "ERROR" "Database '$DB_NAME' is not accessible after $max_wait seconds"
    return 1
}

# Create database if needed (fallback when restore fails)
create_database_if_needed() {
    local db_exists=$(check_database_exists)
    
    if [[ "$db_exists" == "0" ]]; then
        log "INFO" "Creating new database '$DB_NAME' as fallback..."
        
        # Ensure directories exist
        mkdir -p /var/opt/mssql/data /var/opt/mssql/log
        chown mssql:root /var/opt/mssql/data /var/opt/mssql/log
        chmod 755 /var/opt/mssql/data /var/opt/mssql/log
        
        local create_sql="
        CREATE DATABASE [$DB_NAME]
        ON (NAME = '${DB_NAME}',
            FILENAME = '/var/opt/mssql/data/${DB_NAME}.mdf',
            SIZE = 1GB,
            MAXSIZE = UNLIMITED,
            FILEGROWTH = 256MB)
        LOG ON (NAME = '${DB_NAME}_log',
                FILENAME = '/var/opt/mssql/log/${DB_NAME}_log.ldf',
                SIZE = 256MB,
                MAXSIZE = UNLIMITED,
                FILEGROWTH = 64MB);
        
        ALTER DATABASE [$DB_NAME] SET RECOVERY SIMPLE;
        ALTER DATABASE [$DB_NAME] SET COMPATIBILITY_LEVEL = 150;
        
        PRINT 'Database created successfully: $DB_NAME';
        "
        
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
            -Q "$create_sql" -t 300; then
            log "SUCCESS" "Database '$DB_NAME' created successfully"
            sleep 5
            if wait_for_database_access; then
                return 0
            else
                log "ERROR" "Created database is not accessible"
                return 1
            fi
        else
            log "ERROR" "Failed to create database '$DB_NAME'"
            return 1
        fi
    else
        log "INFO" "Database '$DB_NAME' already exists"
        if wait_for_database_access; then
            return 0
        else
            log "ERROR" "Existing database is not accessible"
            return 1
        fi
    fi
}
# functions for safe backup with logic names and with permission   fixes --------------------
fix_database_permissions_after_restore() {
    log "INFO" "Applying comprehensive permission fixes to restored database..."
    
    local permission_fix_sql="
    USE [$DB_NAME];
    
    -- Fix orphaned users by dropping them
    DECLARE @sql NVARCHAR(MAX) = '';
    SELECT @sql = @sql + 'DROP USER [' + name + '];' + CHAR(13)
    FROM sys.database_principals 
    WHERE type = 'S' 
      AND principal_id > 4 
      AND name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys')
      AND authentication_type_desc = 'NONE';  -- Orphaned users
    
    IF LEN(@sql) > 0
    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        PRINT 'Error fixing orphaned users';
        PRINT ERROR_MESSAGE();
    END CATCH
    
    -- Ensure sa has full access to the database
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'sa')
    BEGIN
        CREATE USER [sa] FOR LOGIN [sa];
    END
    
    -- Add sa to db_owner role
    IF IS_ROLEMEMBER('db_owner', 'sa') = 0
        ALTER ROLE db_owner ADD MEMBER [sa];
    
    -- Fix any database state issues
    DECLARE @recovery_model VARCHAR(20);
    SELECT @recovery_model = recovery_model_desc FROM sys.databases WHERE name = '$DB_NAME';
    IF @recovery_model != 'SIMPLE'
    BEGIN
        ALTER DATABASE [$DB_NAME] SET RECOVERY SIMPLE;
        PRINT 'Set recovery model to SIMPLE';
    END
    
    -- Clear any database restrictions
    DECLARE @user_access VARCHAR(20);
    SELECT @user_access = user_access_desc FROM sys.databases WHERE name = '$DB_NAME';
    IF @user_access != 'MULTI_USER'
    BEGIN
        ALTER DATABASE [$DB_NAME] SET MULTI_USER WITH ROLLBACK IMMEDIATE;
        PRINT 'Set database to MULTI_USER mode';
    END
    
    -- Update statistics to ensure good performance
    EXEC sp_updatestats;
    PRINT '---PERMISSIONS_FIXED---';
    SELECT 'PERMISSIONS_FIXED' as status;
    "
    
    local fix_output
    if fix_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d master -Q "$permission_fix_sql" -t 300 2>&1); then
        
        if echo "$fix_output" | grep -Eiq "\bPERMISSIONS_FIXED\b"; then
            log "SUCCESS" "Database permissions fixed successfully"
            echo "$fix_output" | grep -E "(Removing|Set|PERMISSIONS_FIXED)" | while IFS= read -r line; do
                [[ -n "$line" ]] && log "INFO" "  $line"
            done
            return 0
        else
            log "WARNING" "Permission fix completed but success marker not found"
            echo "$fix_output" | while IFS= read -r line; do
                [[ -n "$line" ]] && log "DEBUG" "  $line"
            done
        fi
    else
        log "ERROR" "Failed to execute permission fixes"
        echo "$fix_output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line"
        done
    fi
    
    return 1
}
initialize_database_safely() {
    log "INFO" "Starting production-safe database initialization..."
    
    # Step 1: Check if database already exists with data
    local db_status=$(check_database_with_data)
    
    case $db_status in
        "EXISTS_WITH_DATA")
            log "INFO" "Database exists with data. Skipping restore, proceeding to updates..."
            log "INFO" "This is normal for existing production systems"
            return 0  # Database ready, proceed to scripts
            ;;
        "EXISTS_EMPTY")
            log "WARNING" "Database exists but appears empty. This might need investigation."
            log "INFO" "Proceeding with script execution to populate database..."
            return 0  # Proceed to scripts
            ;;
        "NOT_EXISTS")
            log "INFO" "Database does not exist. Will attempt restore from backup..."
            if restore_from_backup_first_time_only; then
                log "SUCCESS" "Initial database restore completed"
                return 0
            else
                log "ERROR" "Failed to restore database from backup"
                return 1
            fi
            ;;
        "EXISTS_INACCESSIBLE")
            log "WARNING" "Database exists but is not accessible. Attempting to fix permissions..."
            if fix_database_permissions_after_restore; then
                log "SUCCESS" "Database access restored"
                return 0
            else
                log "ERROR" "Could not restore database access"
                return 1
            fi
            ;;
        *)
            log "ERROR" "Unknown database status: $db_status"
            return 1
            ;;
    esac
}

check_database_with_data() {
    local db_name="${1:-$DB_NAME}"
    
    log "DEBUG" "Checking database '$db_name' existence and data status..."
    
    # Add retry logic for connection issues
    local max_retries=3
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        # Check if database exists with improved query and output handling
        local db_exists
        local sql_check_exists="SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$db_name') IS NOT NULL THEN 1 ELSE 0 END AS db_exists"
        
        if db_exists=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
            -d master -h-1 -W -b -Q "$sql_check_exists" -t 30 2>/dev/null | \
            grep -E '^[0-9]+$' | head -1 | tr -d ' \n\r\t'); then
            
            log "DEBUG" "Database existence check result: '$db_exists'"
            
            if [[ "$db_exists" == "1" ]]; then
                log "DEBUG" "Database '$db_name' exists in SQL Server metadata"
                
                # Check if database is online and accessible
                local db_state
                local sql_check_state="SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$db_name'"
                
                if db_state=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
                    -d master -h-1 -W -b -Q "$sql_check_state" -t 30 2>/dev/null | \
                    grep -v '^$' | tail -1 | tr -d ' \n\r\t'); then
                    
                    log "DEBUG" "Database state: '$db_state'"
                    
                    if [[ "$db_state" != "ONLINE" ]]; then
                        log "WARNING" "Database '$db_name' exists but is not ONLINE (state: $db_state)"
                        echo "EXISTS_INACCESSIBLE"
                        return 0
                    fi
                fi
                
                # Check table count with better error handling
                local table_count
                local sql_check_tables="SET NOCOUNT ON; USE [$db_name]; SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'"
                
                if table_count=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
                    -d master -h-1 -W -b -Q "$sql_check_tables" -t 30 2>/dev/null | \
                    grep -E '^[0-9]+$' | head -1 | tr -d ' \n\r\t'); then
                    
                    log "DEBUG" "Database '$db_name' is accessible with $table_count tables"
                    
                    if [[ -n "$table_count" && "$table_count" -gt "0" ]]; then
                        # Additional verification - check for actual data
                        local has_meaningful_data
                        local sql_check_data="SET NOCOUNT ON; USE [$db_name]; 
                        SELECT CASE 
                            WHEN EXISTS(
                                SELECT 1 FROM INFORMATION_SCHEMA.TABLES 
                                WHERE TABLE_TYPE = 'BASE TABLE' 
                                AND TABLE_NAME NOT LIKE 'sys%' 
                                AND TABLE_NAME NOT LIKE '__MigrationHistory%'
                            ) THEN 1 ELSE 0 END"
                        
                        if has_meaningful_data=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
                            -d master -h-1 -W -b -Q "$sql_check_data" -t 30 2>/dev/null | \
                            grep -E '^[0-1]+$' | head -1 | tr -d ' \n\r\t'); then
                            
                            if [[ "$has_meaningful_data" == "1" ]]; then
                                log "DEBUG" "Database has meaningful data tables"
                                echo "EXISTS_WITH_DATA"
                                return 0
                            else
                                log "DEBUG" "Database exists but has no meaningful data"
                                echo "EXISTS_EMPTY"
                                return 0
                            fi
                        else
                            log "DEBUG" "Cannot verify data content, assuming has data"
                            echo "EXISTS_WITH_DATA"
                            return 0
                        fi
                    else
                        log "DEBUG" "Database has no tables"
                        echo "EXISTS_EMPTY"
                        return 0
                    fi
                else
                    log "WARNING" "Database '$db_name' exists but table count query failed"
                    
                    # Try alternative check - can we at least connect to the database?
                    local connection_test
                    if connection_test=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
                        -d "$db_name" -h-1 -W -b -Q "SET NOCOUNT ON; SELECT 1" -t 10 2>/dev/null); then
                        
                        log "DEBUG" "Database connection successful, treating as having data"
                        echo "EXISTS_WITH_DATA"
                        return 0
                    else
                        log "WARNING" "Database exists but is not accessible"
                        echo "EXISTS_INACCESSIBLE"
                        return 0
                    fi
                fi
            else
                log "DEBUG" "Database '$db_name' does not exist"
                echo "NOT_EXISTS"
                return 0
            fi
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log "WARNING" "Database check attempt $retry_count failed, retrying in 5 seconds..."
                sleep 5
            else
                log "ERROR" "Cannot connect to SQL Server after $max_retries attempts"
                echo "CONNECTION_FAILED"
                return 1
            fi
        fi
    done
}

restore_from_backup_first_time_only() {
    log "INFO" "Attempting first-time database restore from backup..."
    
    # Double-check that database doesn't exist (safety check)
    local db_status=$(check_database_with_data)
    if [[ "$db_status" == "EXISTS_WITH_DATA" ]]; then
        log "ERROR" "SAFETY CHECK FAILED: Database with data already exists!"
        log "ERROR" "Refusing to restore over existing data. This prevents data loss."
        return 1
    fi
    
    # Get backup path
    local backup_path
    backup_path=$(get_backup_path)
    local get_backup_result=$?
    
    if [[ $get_backup_result -ne 0 || -z "$backup_path" ]]; then
        log "ERROR" "No backup file found for initial restore"
        return 1
    fi
    
    log "INFO" "Starting FIRST-TIME restore from: $backup_path"
    
    # Get logical file names with proper error handling
    local logical_names
    logical_names=$(get_backup_logical_names "$backup_path")
    local logical_names_exit_code=$?
    
    if [[ $logical_names_exit_code -ne 0 || -z "$logical_names" ]]; then
        log "ERROR" "Failed to retrieve logical file names from backup"
        return 1
    fi
    
    # Parse the logical names
    local data_logical_name=$(echo "$logical_names" | cut -d'|' -f1)
    local log_logical_name=$(echo "$logical_names" | cut -d'|' -f2)
    
    # Validate that we have clean logical names
    if [[ -z "$data_logical_name" || -z "$log_logical_name" ]]; then
        log "ERROR" "Invalid logical names extracted: DATA='$data_logical_name', LOG='$log_logical_name'"
        return 1
    fi
    
    # Additional validation to ensure no contamination
    if [[ "$data_logical_name" =~ [[:space:]].*INFO.*|.*ERROR.* ]] || [[ "$log_logical_name" =~ [[:space:]].*INFO.*|.*ERROR.* ]]; then
        log "ERROR" "Logical names appear to be contaminated with log messages"
        log "ERROR" "DATA name: '$data_logical_name'"
        log "ERROR" "LOG name: '$log_logical_name'"
        return 1
    fi
    
    log "INFO" "Using logical names - DATA: '$data_logical_name', LOG: '$log_logical_name'"
    
    # Ensure target directories exist
    mkdir -p /var/opt/mssql/data /var/opt/mssql/log
    chown mssql:root /var/opt/mssql/data /var/opt/mssql/log
    chmod 755 /var/opt/mssql/data /var/opt/mssql/log
    
    # Define target file paths
    local target_data_file="/var/opt/mssql/data/${DB_NAME}.mdf"
    local target_log_file="/var/opt/mssql/log/${DB_NAME}_log.ldf"
    
    # MINIMAL cleanup - only if database exists but is empty/broken
    if [[ "$db_status" == "EXISTS_EMPTY" || "$db_status" == "EXISTS_INACCESSIBLE" ]]; then
        log "INFO" "Cleaning up empty/broken database for fresh restore..."
        /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master -Q "
            IF DB_ID(N'$DB_NAME') IS NOT NULL
            BEGIN
                ALTER DATABASE [$DB_NAME] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE [$DB_NAME];
                PRINT 'Dropped empty/broken database for fresh restore';
            END
        " -t 60 2>/dev/null || true
        
        # Clean up files
        rm -f "$target_data_file" "$target_log_file" 2>/dev/null || true
        sleep 5
    fi
    
    # Execute restore with comprehensive error handling
    # Use proper SQL escaping for the logical names
    local restore_sql="
    SET NOCOUNT ON;
    PRINT 'Starting FIRST-TIME restore of database: $DB_NAME';
    PRINT 'This is a one-time operation for migration from Windows to Linux';
    
    -- Restore the database
    RESTORE DATABASE [$DB_NAME]
    FROM DISK = N'${backup_path}'
    WITH 
        MOVE N'${data_logical_name}' TO N'${target_data_file}',
        MOVE N'${log_logical_name}' TO N'${target_log_file}',
        REPLACE,
        STATS = 5;
    
    PRINT 'Database restored, applying configuration...';
    
    -- Configure database for Linux environment
    ALTER DATABASE [$DB_NAME] SET MULTI_USER WITH ROLLBACK IMMEDIATE;
    ALTER DATABASE [$DB_NAME] SET COMPATIBILITY_LEVEL = 150;
    ALTER DATABASE [$DB_NAME] SET RECOVERY SIMPLE;
    ALTER DATABASE [$DB_NAME] SET ONLINE;
    
    PRINT 'First-time restore completed successfully';
    SELECT 'FIRST_TIME_RESTORE_SUCCESS' as RestoreStatus;
    "
    
    log "INFO" "Executing first-time restore (this may take 30+ minutes for 50GB database)..."
    log "DEBUG" "RESTORE command will use: DATA='$data_logical_name', LOG='$log_logical_name'"
    
    local restore_output
    if restore_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d master -Q "$restore_sql" -t 3600 2>&1); then  # 1 hour timeout for large DB
        
        log "INFO" "Restore command completed, checking results..."
        
        # Show progress
        echo "$restore_output" | grep -E "(percent|processed|completed|FIRST_TIME_RESTORE_SUCCESS)" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "INFO" "  $line"
        done
        
        if echo "$restore_output" | grep -q "FIRST_TIME_RESTORE_SUCCESS"; then
            log "SUCCESS" "First-time database restore completed successfully!"
            
            # Apply permission fixes
            if fix_database_permissions_after_restore; then
                log "SUCCESS" "Database permissions configured for Linux environment"
                
                # Create initialization marker to prevent future restores
                echo "$(date): First-time restore completed from $backup_path" > /var/opt/mssql/data/.restore_completed
                echo "Database size: $(du -sh /var/opt/mssql/data/${DB_NAME}.mdf 2>/dev/null || echo 'Unknown')" >> /var/opt/mssql/data/.restore_completed
                
                return 0
            else
                log "WARNING" "Database restored but permission configuration failed"
            fi
        else
            log "ERROR" "First-time restore failed"
            echo "$restore_output" | while IFS= read -r line; do
                [[ -n "$line" ]] && log "ERROR" "  $line"
            done
        fi
    else
        log "ERROR" "First-time restore command failed"
        echo "$restore_output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line"
        done
    fi
    
    return 1
}
debug_database_status() {
    local db_name="${1:-$DB_NAME}"
    
    echo "=== MANUAL DATABASE STATUS CHECK ==="
    echo "Database name: '$db_name'"
    echo "SA Password set: $(if [[ -n "$SA_PASSWORD" ]]; then echo "YES"; else echo "NO"; fi)"
    echo ""
    
    echo "1. SQL Server Connection Test:"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT @@VERSION" -t 10 2>&1
    echo ""
    
    echo "2. List All Databases:"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT name, state_desc, user_access_desc FROM sys.databases" -t 30 2>&1
    echo ""
    
    echo "3. Check Specific Database:"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
        SELECT 
            name,
            database_id,
            state_desc,
            user_access_desc,
            collation_name
        FROM sys.databases 
        WHERE name = N'$db_name' OR name LIKE '%$(echo "$db_name" | tr '[:upper:]' '[:lower:]')%'
    " -t 30 2>&1
    echo ""
    
    echo "4. Database Files Check:"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
        IF DB_ID(N'$db_name') IS NOT NULL
        BEGIN
            USE [$db_name];
            SELECT 
                name as logical_name,
                physical_name,
                type_desc,
                state_desc,
                size * 8.0 / 1024 as size_mb
            FROM sys.database_files;
        END
        ELSE
            SELECT 'Database $db_name not found' as error_message;
    " -t 30 2>&1
    echo ""
    
    echo "5. Physical File System Check:"
    echo "Data directory contents:"
    ls -la /var/opt/mssql/data/ 2>/dev/null || echo "Cannot access data directory"
    echo ""
    echo "Log directory contents:"
    ls -la /var/opt/mssql/log/ 2>/dev/null || echo "Cannot access log directory"
    echo ""
    
    echo "6. Container Environment Check:"
    echo "Current user: $(whoami)"
    echo "SQL Server process: $(ps aux | grep sqlservr | grep -v grep || echo 'SQL Server process not found')"
    echo "=== END DEBUG ==="
}

# Quick fix function to call before your main initialization
quick_database_fix() {
    local db_name="${1:-$DB_NAME}"
    
    log "INFO" "Attempting quick database accessibility fix..."
    
    # Try to bring database online if it exists but is offline
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master -Q "
        IF DB_ID(N'$db_name') IS NOT NULL
        BEGIN
            DECLARE @state varchar(20);
            SELECT @state = state_desc FROM sys.databases WHERE name = N'$db_name';
            
            IF @state != 'ONLINE'
            BEGIN
                PRINT 'Database found but not ONLINE, attempting to bring online...';
                ALTER DATABASE [$db_name] SET ONLINE;
                PRINT 'Database set to ONLINE';
            END
            ELSE
                PRINT 'Database is already ONLINE';
        END
        ELSE
            PRINT 'Database $db_name not found in sys.databases';
    " -t 60 2>&1
}
#END of safe backup with logic names and with permission   fixes --------------------



#SQL script execution with enhanced error handling
execute_sql() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    local database_context=${2:-$DB_NAME}
    
    # Check if script should be excluded
    if [[ -f "${script_path}.exclude" ]]; then
        log "WARNING" "Skipping excluded script: $script_name"
        return 0
    fi
    
    # Check if script has failed before
    if [[ "${IGNORE_SCRIPT_ERRORS:-false}" == "true" ]] && check_failure_marker "$script_name"; then
        log "WARNING" "Skipping previously failed script: $script_name"
        return 0
    fi
    
    # Log script details
    local script_size=$(stat -f%z "$script_path" 2>/dev/null || stat -c%s "$script_path" 2>/dev/null || echo "unknown")
    log "INFO" "=== EXECUTING SCRIPT ==="
    log "INFO" "Script: $script_name"
    log "INFO" "Path: $script_path"
    log "INFO" "Size: $script_size bytes"
    log "INFO" "Database: $database_context"
    log "INFO" "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Preview first few lines of script (for debugging)
    log "DEBUG" "Script Preview (first 5 lines):"
    head -5 "$script_path" | while IFS= read -r line; do
        log "DEBUG" "  $line"
    done
    
    # Create a temporary script with proper SET options
    local temp_script="/tmp/temp_script_${script_name}_${RANDOM}.sql"
    cat > "$temp_script" << 'EOF'
-- Enhanced SQL Server settings for better compatibility
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET IMPLICIT_TRANSACTIONS OFF;
SET CURSOR_CLOSE_ON_COMMIT OFF;
SET CURSOR_DEFAULT GLOBAL;

-- Error handling
SET XACT_ABORT ON;

-- Performance settings
SET LOCK_TIMEOUT 30000;
SET QUERY_GOVERNOR_COST_LIMIT 0;

-- Add execution logging
PRINT '=== STARTING SCRIPT EXECUTION ===';
PRINT 'Script: ' + '$script_name';
PRINT 'Database: ' + DB_NAME();
PRINT 'Start Time: ' + CONVERT(VARCHAR(20), GETDATE(), 120);
PRINT '================================';

GO

EOF
    cat "$script_path" >> "$temp_script"
    
    # Add completion marker
    cat >> "$temp_script" << EOF

-- Script completion logging
PRINT '=== SCRIPT EXECUTION COMPLETED ===';
PRINT 'Script: $script_name';
PRINT 'End Time: ' + CONVERT(VARCHAR(20), GETDATE(), 120);
PRINT 'Status: SUCCESS';
PRINT '==================================';

GO
EOF
    
    # Execute with comprehensive error handling and detailed output
    local start_time=$(date +%s)
    local output
    log "INFO" "Executing SQL script..."
    
    if output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$database_context" -i "$temp_script" -b -V 16 -t 600 -r1 2>&1); then
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "✓ Script executed successfully: $script_name"
        log "INFO" "Execution time: ${duration} seconds"
        
        # Log detailed output
        log "INFO" "=== SCRIPT OUTPUT ==="
        echo "$output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "SQL_OUTPUT" "$line"
        done
        log "INFO" "=== END OUTPUT ==="
        
        # Log success to tracking file
        echo "$(date '+%Y-%m-%d %H:%M:%S'): SUCCESS: $script_name (${duration}s)" >> /var/opt/mssql/data/.script_execution_log
        
        rm -f "$temp_script"
        return 0
    else
        local exit_code=$?
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "ERROR" "✗ Failed to execute: $script_name (exit code: $exit_code)"
        log "ERROR" "Execution time: ${duration} seconds"
        
        # Show detailed error information
        log "ERROR" "=== ERROR DETAILS ==="
        echo "$output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "SQL_ERROR: $line"
        done
        log "ERROR" "=== END ERROR DETAILS ==="
        
        # Mark script as failed with detailed info
        create_failure_marker "$script_name" "Exit code: $exit_code, Duration: ${duration}s"
        
        # Log failure to tracking file
        echo "$(date '+%Y-%m-%d %H:%M:%S'): FAILED: $script_name (${duration}s) - Exit code: $exit_code" >> /var/opt/mssql/data/.script_execution_log
        
        rm -f "$temp_script"
        
        if [[ "${IGNORE_SCRIPT_ERRORS:-false}" != "true" ]]; then
            log "ERROR" "Script execution failed and IGNORE_SCRIPT_ERRORS is not set to true. Stopping."
            exit 1
        else
            log "WARNING" "Script failed but continuing due to IGNORE_SCRIPT_ERRORS=true"
            return 1
        fi
    fi
}
validate_user_mappings() {
    log "INFO" "=== VALIDATING USER MAPPINGS ==="
    
    # Check all created users for orphaned mappings
    local validation_sql="
    USE [$DB_NAME];
    
    SELECT 
        dp.name as UserName,
        CASE WHEN sp.name IS NOT NULL THEN 'MAPPED' ELSE 'ORPHANED' END as Status,
        CASE WHEN sp.name IS NOT NULL THEN sp.name ELSE 'NO_LOGIN' END as MappedLogin
    FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE dp.name IN ('${DB_READ_USER:-db_reader}', '${DB_EXECUTE_USER:-db_executor}', '${DB_APP_USER:-db_application}')
        AND dp.type IN ('S', 'U')
    ORDER BY dp.name;
    "
    
    local validation_result
    if validation_result=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "$validation_sql" -h-1 -W -t 30 2>&1); then
        
        # Check for orphaned users
        if echo "$validation_result" | grep -q "ORPHANED"; then
            log "WARNING" "Found orphaned users - fixing automatically..."
            
            # Auto-fix orphaned users
            echo "$validation_result" | grep "ORPHANED" | while read -r username status login; do
                log "INFO" "Fixing orphaned user: $username"
                /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
                    USE [$DB_NAME];
                    EXEC sp_change_users_login 'Update_One', '$username', '$username';
                " -t 30 >/dev/null 2>&1 && \
                    log "SUCCESS" "Fixed mapping for $username" || \
                    log "WARNING" "Could not fix mapping for $username"
            done
        else
            log "SUCCESS" "All user mappings are valid"
        fi
        
        # Display final status
        echo "$validation_result" | while read -r username status login; do
            if [[ "$status" == "MAPPED" ]]; then
                log "SUCCESS" "✓ $username -> $login"
            else
                log "WARNING" "⚠ $username -> $login"
            fi
        done
    fi
}
# Create users with enhanced error handling
create_database_users() {
    log "INFO" "Creating database users and roles..."
    
    # Ensure database is accessible first
    if ! verify_database_access; then
        log "ERROR" "Cannot access database for user creation"
        return 1
    fi
    
    # Create roles first
    local role_sql="
    USE [$DB_NAME];
    
    -- Create custom database roles if they don't exist
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'db_reader_role' AND type = 'R')
    BEGIN
        CREATE ROLE db_reader_role;
        PRINT 'Created db_reader_role';
    END
    
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'db_executor_role' AND type = 'R')
    BEGIN
        CREATE ROLE db_executor_role;
        PRINT 'Created db_executor_role';
    END
    
    IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'db_application_role' AND type = 'R')
    BEGIN
        CREATE ROLE db_application_role;
        PRINT 'Created db_application_role';
    END
    
    -- Grant basic permissions to roles
    GRANT SELECT ON SCHEMA::dbo TO db_reader_role;
    GRANT SELECT, INSERT, UPDATE ON SCHEMA::dbo TO db_executor_role;
    GRANT EXECUTE ON SCHEMA::dbo TO db_executor_role;
    GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO db_application_role;
    GRANT EXECUTE ON SCHEMA::dbo TO db_application_role;
    
    SELECT 'ROLES_CREATED' as status;
    "
    
    if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d master -Q "$role_sql" -t 60 2>/dev/null | grep -q "ROLES_CREATED"; then
        log "SUCCESS" "Database roles created successfully"
    else
        log "WARNING" "Failed to create some database roles"
    fi
    
    # Create individual users (your existing logic)
    local users=("${DB_READ_USER:-db_reader}" "${DB_EXECUTE_USER:-db_executor}" "${DB_APP_USER:-db_application}")
    local passwords=("${DB_READ_PASSWORD}" "${DB_EXECUTE_PASSWORD}" "${DB_APP_PASSWORD}")
    local roles=("db_reader_role" "db_executor_role" "db_application_role")
    
    for i in "${!users[@]}"; do
        local username="${users[i]}"
        local password="${passwords[i]}"
        local role="${roles[i]}"
        
        if [[ -n "$password" ]]; then
            log "INFO" "Creating user: $username"
            
            # Create login
            /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "
                IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = '$username')
                BEGIN
                    CREATE LOGIN [$username] WITH PASSWORD = '$password', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
                    PRINT 'Created login: $username';
                END
            " -t 30 2>/dev/null || true
            
            # Create user and assign role
            /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$DB_NAME" -Q "
                IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = '$username')
                BEGIN
                    CREATE USER [$username] FOR LOGIN [$username];
                    PRINT 'Created user: $username';
                END
                
                IF IS_ROLEMEMBER('$role', '$username') = 0
                BEGIN
                    ALTER ROLE $role ADD MEMBER [$username];
                    PRINT 'Added $username to $role';
                END
                
                SELECT 'USER_CREATED: $username' as status;
            " -t 30 2>/dev/null | grep -q "USER_CREATED" && \
                log "SUCCESS" "User $username configured" || \
                log "WARNING" "Issues configuring user $username"
        fi
    done
    validate_user_mappings
}

# Execute scripts in folder
execute_scripts_in_folder() {
    local folder_path=$1
    local folder_name=$2
    local batch_size=${BATCH_SIZE:-20}  # Keep your current batch size
    
    log "INFO" "=== PROCESSING FOLDER: $folder_name ==="
    log "INFO" "Folder path: $folder_path"
    log "INFO" "Batch size: $batch_size scripts per batch"
    
    if [[ ! -d "$folder_path" ]]; then
        log "WARNING" "Folder $folder_path not found, skipping $folder_name scripts"
        return 0
    fi
    
    # Find SQL scripts with detailed search
    local scripts=($(find "$folder_path" -name "*.sql" -type f | sort))
    
    log "INFO" "Found ${#scripts[@]} SQL scripts in $folder_path"
    
    if [[ ${#scripts[@]} -eq 0 ]]; then
        log "WARNING" "No SQL scripts found in $folder_path"
        return 0
    fi
    
    local success_count=0
    local failure_count=0
    local skipped_count=0
    local total_scripts=${#scripts[@]}
    local batch_num=1
    
    log "INFO" "Starting execution of $total_scripts scripts..."
    
    # Process scripts in batches
    for ((i=0; i<$total_scripts; i+=$batch_size)); do
        local batch_scripts=("${scripts[@]:$i:$batch_size}")
        local batch_count=${#batch_scripts[@]}
        local batch_start=$((i + 1))
        local batch_end=$((i + batch_count))
        
        log "INFO" "=== BATCH $batch_num: Processing scripts $batch_start-$batch_end of $total_scripts ==="
        
        # Process each script in the current batch
        for script in "${batch_scripts[@]}"; do
            local script_name=$(basename "$script")
            local current_position=$((success_count + failure_count + skipped_count + 1))
            
            # Check if script should be skipped
            if [[ -f "${script}.exclude" ]]; then
                log "INFO" "⊘ [$current_position/$total_scripts] Skipping excluded script: $script_name"
                ((skipped_count++))
                continue
            fi
            
            log "INFO" "[$current_position/$total_scripts] Processing: $script_name"
            
            # Execute script with proper error handling
            local script_result=0
            if ! execute_sql "$script"; then
                script_result=1
            fi
            
            if [[ $script_result -eq 0 ]]; then
                ((success_count++))
                log "SUCCESS" "✓ [$current_position/$total_scripts] Completed: $script_name"
            else
                ((failure_count++))
                log "ERROR" "✗ [$current_position/$total_scripts] Failed: $script_name"
                
                # Continue processing even if IGNORE_SCRIPT_ERRORS is false
                # but log the failure for later review
                if [[ "${IGNORE_SCRIPT_ERRORS:-false}" != "true" ]]; then
                    log "WARNING" "Script failed but continuing execution. Set IGNORE_SCRIPT_ERRORS=true to suppress this warning."
                fi
            fi
            
            # Small delay between scripts to prevent overwhelming the system
            sleep 0.5
        done
        
        # Batch completion summary
        log "INFO" "=== BATCH $batch_num COMPLETE ==="
        log "INFO" "Overall progress: $((success_count + skipped_count))/$total_scripts completed, $failure_count failed"
        
        # Brief pause between batches
        if [[ $batch_num -lt $(((total_scripts + batch_size - 1) / batch_size)) ]]; then
            log "INFO" "Pausing 2 seconds between batches..."
            sleep 2
        fi
        
        ((batch_num++))
    done
    
    # Final summary report
    log "INFO" "=== FOLDER EXECUTION SUMMARY: $folder_name ==="
    log "INFO" "Total scripts found: $total_scripts"
    log "INFO" "Successfully executed: $success_count"
    log "INFO" "Failed: $failure_count"
    log "INFO" "Skipped: $skipped_count"
    
    if [[ $((total_scripts - skipped_count)) -gt 0 ]]; then
        log "INFO" "Success rate: $(( (success_count * 100) / (total_scripts - skipped_count) ))%"
    fi
    
    if [[ $failure_count -gt 0 ]]; then
        log "WARNING" "$folder_name scripts completed with $failure_count failures out of $total_scripts total"
    else
        log "SUCCESS" "✓ All $folder_name scripts executed successfully ($success_count/$total_scripts)"
    fi
    
    log "INFO" "=== END FOLDER: $folder_name ==="
    echo ""  # Add blank line for readability
}

# Fixed execute_sql function with better error handling
execute_sql() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    local database_context=${2:-$DB_NAME}
    
    # Check if script should be excluded
    if [[ -f "${script_path}.exclude" ]]; then
        log "WARNING" "Skipping excluded script: $script_name"
        return 0
    fi
    
    log "INFO" "=== EXECUTING SCRIPT ==="
    log "INFO" "Script: $script_name"
    log "INFO" "Database: $database_context"
    log "INFO" "Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Create a simpler temporary script
    local temp_script="/tmp/temp_script_$$_${RANDOM}.sql"
    
    # Create temp script with better error handling
    {
        echo "-- Script execution: $script_name"
        echo "SET ANSI_NULLS ON;"
        echo "SET QUOTED_IDENTIFIER ON;"
        echo "SET XACT_ABORT ON;"
        echo "GO"
        echo ""
        cat "$script_path"
        echo ""
        echo "GO"
    } > "$temp_script"
    
    # Execute with timeout and better error capture
    local start_time=$(date +%s)
    local exit_code=0
    local output=""
    
    # Use timeout to prevent hanging
    if command -v timeout >/dev/null 2>&1; then
        output=$(timeout 300 /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
            -d "$database_context" -i "$temp_script" -b -V 1 -t 30 2>&1) || exit_code=$?
    else
        output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
            -d "$database_context" -i "$temp_script" -b -V 1 -t 30 2>&1) || exit_code=$?
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Clean up temp file immediately
    rm -f "$temp_script" 2>/dev/null || true
    
    # Process results
    if [[ $exit_code -eq 0 ]]; then
        log "SUCCESS" "✓ Script executed successfully: $script_name (${duration}s)"
        
        # Log non-empty output only
        if [[ -n "$output" ]] && [[ "$output" != *"rows affected"* ]]; then
            log "DEBUG" "Script output: $output"
        fi
        
        return 0
    else
        log "ERROR" "✗ Failed to execute: $script_name (exit code: $exit_code, ${duration}s)"
        
        # Log error details
        if [[ -n "$output" ]]; then
            log "ERROR" "Error details: $output"
        fi
        
        # Always return 1 for failures, let the calling function decide what to do
        return 1
    fi
}

# SQL Server health check function
check_sql_server_health() {
    log "DEBUG" "Checking SQL Server health..."
    
    # Test basic connectivity
    if ! /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT 1" -t 10 >/dev/null 2>&1; then
        log "WARNING" "SQL Server connectivity check failed"
        return 1
    fi
    
    # Check memory usage
    local memory_check=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -Q "SELECT cntr_value FROM sys.dm_os_performance_counters WHERE counter_name = 'Target Server Memory (KB)'" \
        -h -1 -W 2>/dev/null | tr -d ' \r\n' | head -1)
    
    if [[ -n "$memory_check" && "$memory_check" =~ ^[0-9]+$ ]]; then
        log "DEBUG" "SQL Server memory target: ${memory_check}KB"
    else
        log "WARNING" "Could not retrieve SQL Server memory information"
    fi
    
    return 0
}

# SQL Server recovery function
recover_sql_server() {
    log "INFO" "Attempting SQL Server recovery..."
    
    # Wait a moment
    sleep 3
    
    # Try to reconnect
    local retry_count=0
    while [[ $retry_count -lt 5 ]]; do
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SELECT 'Recovery test'" -t 15 >/dev/null 2>&1; then
            log "SUCCESS" "SQL Server recovery successful"
            return 0
        fi
        
        ((retry_count++))
        log "WARNING" "Recovery attempt $retry_count/5 failed. Waiting..."
        sleep $((retry_count * 2))
    done
    
    log "ERROR" "SQL Server recovery failed after 5 attempts"
    return 1
}

# Memory cleanup function
cleanup_sql_server_memory() {
    log "DEBUG" "Performing SQL Server memory cleanup..."
    
    # Execute cleanup commands
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -Q "DBCC FREESYSTEMCACHE('ALL'); DBCC FREESESSIONCACHE; CHECKPOINT;" \
        -t 30 >/dev/null 2>&1 || log "WARNING" "Memory cleanup command failed"
    
    log "DEBUG" "Memory cleanup completed"
}

# Apply post-script permissions
apply_post_script_permissions() {
    log "INFO" "Applying post-script permissions..."
    
    local perm_sql="
    SET NOCOUNT ON;
    
    DECLARE @sql NVARCHAR(MAX) = ''
    DECLARE @table_count INT = 0
    
    -- Count tables first
    SELECT @table_count = COUNT(*)
    FROM INFORMATION_SCHEMA.TABLES 
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'
    
    IF @table_count > 0
    BEGIN
        -- Grant permissions on all user tables
        SELECT @sql = @sql + 
            'GRANT SELECT ON [' + TABLE_SCHEMA + '].[' + TABLE_NAME + '] TO db_reader_role;' + CHAR(13) +
            'GRANT SELECT, INSERT, UPDATE ON [' + TABLE_SCHEMA + '].[' + TABLE_NAME + '] TO db_executor_role;' + CHAR(13) +
            'GRANT SELECT, INSERT, UPDATE, DELETE ON [' + TABLE_SCHEMA + '].[' + TABLE_NAME + '] TO db_application_role;' + CHAR(13)
        FROM INFORMATION_SCHEMA.TABLES 
        WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo'
        
        IF LEN(@sql) > 0
        BEGIN
            EXEC sp_executesql @sql
            SELECT 'PERMISSIONS_APPLIED' as status
        END
    END
    ELSE
    BEGIN
        SELECT 'NO_TABLES_FOUND' as status
    END
    "
    
    local result
    if result=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$DB_NAME" -Q "$perm_sql" -h-1 -t 60 2>/dev/null); then
        if echo "$result" | grep -q "PERMISSIONS_APPLIED"; then
            log "SUCCESS" "Post-script permissions applied successfully"
        elif echo "$result" | grep -q "NO_TABLES_FOUND"; then
            log "INFO" "No tables found - permissions will be applied after table creation"
        else
            log "WARNING" "Permissions applied with warnings"
        fi
    else
        log "WARNING" "Some post-script permissions may not have been applied"
    fi
}

# Check initialization status
check_initialization_needed() {
    local db_exists=$(check_database_exists)
    
    if [[ "$db_exists" == "1" ]]; then
        local table_count=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$DB_NAME" -h -1 -Q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'" -t 30 2>/dev/null | tr -d ' \n\r')
        
        if [[ "$table_count" -gt "0" ]]; then
            log "INFO" "Database exists with $table_count tables - running script updates only"
            return 1  # Skip initial setup
        else
            log "INFO" "Database exists but is empty - full initialization needed"
            return 0  # Full initialization needed
        fi
    else
        log "INFO" "Database does not exist - full initialization needed"
        return 0  # Full initialization needed
    fi
}

# Enhanced cleanup function
cleanup() {
    log "INFO" "Received shutdown signal, performing graceful cleanup..."
    
    # Stop SQL Server gracefully
    if [[ -n "$SERVER_PID" ]]; then
        log "INFO" "Stopping SQL Server (PID: $SERVER_PID)..."
        
        # Try graceful shutdown first
        /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -Q "SHUTDOWN" -t 30 2>/dev/null || true
        
        # Wait for graceful shutdown
        local timeout=30
        local count=0
        while kill -0 $SERVER_PID 2>/dev/null && [ $count -lt $timeout ]; do
            sleep 1
            ((count++))
        done
        
        # Force kill if still running
        if kill -0 $SERVER_PID 2>/dev/null; then
            log "WARNING" "Forcing SQL Server shutdown..."
            kill -TERM $SERVER_PID 2>/dev/null || true
            sleep 5
            kill -KILL $SERVER_PID 2>/dev/null || true
        fi
        
        wait $SERVER_PID 2>/dev/null || true
    fi
    
    log "INFO" "Cleanup completed"
    exit 0
}

test_user_specific_permissions() {
    local username=$1
    local password=$2
    
    log "DEBUG" "Testing specific permissions for user: $username"
    
    # Determine expected role based on username
    local expected_role=""
    case "$username" in
        "${DB_READ_USER:-BBTDev}")
            expected_role="db_reader_role"
            # Test SELECT permission
            local select_test
            if select_test=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U "$username" -P "$password" \
                -d "$DB_NAME" -Q "SELECT TOP 1 name FROM sys.tables" -h-1 -W -t 15 2>&1); then
                log "SUCCESS" "  ✓ $username has SELECT permissions (reader role)"
            else
                log "WARNING" "  ⚠ $username may not have proper SELECT permissions"
            fi
            ;;
        "${DB_EXECUTE_USER:-BBTAdmin}")
            expected_role="db_executor_role"
            # Test SELECT and potential EXECUTE permissions
            local exec_test
            if exec_test=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U "$username" -P "$password" \
                -d "$DB_NAME" -Q "SELECT COUNT(*) FROM sys.procedures" -h-1 -W -t 15 2>&1); then
                log "SUCCESS" "  ✓ $username has SELECT permissions (executor role)"
            else
                log "WARNING" "  ⚠ $username may not have proper permissions"
            fi
            ;;
        "${DB_APP_USER:-admindb}")
            expected_role="db_application_role"
            # Test comprehensive permissions
            local app_test
            if app_test=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U "$username" -P "$password" \
                -d "$DB_NAME" -Q "SELECT COUNT(*) FROM sys.tables; SELECT COUNT(*) FROM sys.procedures;" -h-1 -W -t 15 2>&1); then
                log "SUCCESS" "  ✓ $username has comprehensive database access (application role)"
            else
                log "WARNING" "  ⚠ $username may not have proper application permissions"
            fi
            ;;
    esac
}

# Diagnose user login issues
diagnose_user_login_issue() {
    local username=$1
    
    log "DEBUG" "Diagnosing login issue for user: $username"
    
    # Check if login exists at server level
    local login_check
    if login_check=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d master \
        -Q "SELECT name, is_disabled, is_policy_checked, is_expiration_checked FROM sys.server_principals WHERE name = '$username'" -h-1 -W -t 15 2>&1); then
        
        if [[ -n "$login_check" && "$login_check" != *"0 rows affected"* ]]; then
            log "INFO" "  → Server login exists for $username"
            echo "$login_check" | while IFS= read -r line; do
                [[ -n "$line" ]] && log "DEBUG" "    Login details: $line"
            done
        else
            log "ERROR" "  → Server login does NOT exist for $username"
        fi
    fi
    
    # Check if database user exists
    local user_check
    if user_check=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" -d "$DB_NAME" \
        -Q "SELECT name, type_desc FROM sys.database_principals WHERE name = '$username'" -h-1 -W -t 15 2>&1); then
        
        if [[ -n "$user_check" && "$user_check" != *"0 rows affected"* ]]; then
            log "INFO" "  → Database user exists for $username"
        else
            log "ERROR" "  → Database user does NOT exist for $username"
        fi
    fi
}
diagnose_admindb_issue() {
    log "INFO" "=== DIAGNOSING ADMINDB USER ISSUE ==="
    
    # Check server-level login
    local server_check_sql="
    SELECT 
        'SERVER_LOGIN' as CheckType,
        name as LoginName,
        type_desc as LoginType,
        is_disabled,
        default_database_name,
        CASE WHEN is_policy_checked = 1 THEN 'Policy Enforced' ELSE 'Policy Disabled' END as PolicyStatus
    FROM sys.server_principals 
    WHERE name = 'admindb';
    
    -- Check database access permissions at server level
    SELECT 
        'DATABASE_ACCESS' as CheckType,
        sp.name as LoginName,
        d.name as DatabaseName,
        CASE WHEN dp.name IS NOT NULL THEN 'Has Database User' ELSE 'No Database User' END as UserStatus
    FROM sys.server_principals sp
    CROSS JOIN sys.databases d
    LEFT JOIN sys.database_principals dp ON sp.name = dp.name 
        AND d.database_id = DB_ID('$DB_NAME') 
        AND dp.type IN ('S', 'U')
    WHERE sp.name = 'admindb' AND d.name = '$DB_NAME';
    "
    
    log "INFO" "Checking server-level login status..."
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d master -Q "$server_check_sql" -s"|" -W -t 30
    
    # Check database-level user
    local db_check_sql="
    USE [$DB_NAME];
    
    SELECT 
        'DB_USER_INFO' as CheckType,
        dp.name as UserName,
        dp.type_desc as UserType,
        dp.authentication_type_desc as AuthType,
        ISNULL(sp.name, 'NO_LOGIN_MAPPING') as MappedLogin
    FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE dp.name = 'admindb';
    
    -- Check role memberships
    SELECT 
        'ROLE_MEMBERSHIP' as CheckType,
        dp.name as UserName,
        r.name as RoleName,
        CASE WHEN rm.member_principal_id IS NOT NULL THEN 'Member' ELSE 'Not Member' END as MembershipStatus
    FROM sys.database_principals dp
    LEFT JOIN sys.database_role_members rm ON dp.principal_id = rm.member_principal_id
    LEFT JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE dp.name = 'admindb';
    
    -- Check explicit permissions
    SELECT 
        'USER_PERMISSIONS' as CheckType,
        pr.name as UserName,
        p.permission_name,
        p.state_desc as PermissionState,
        ISNULL(s.name, 'DATABASE') as SchemaName
    FROM sys.database_permissions p
    JOIN sys.database_principals pr ON p.grantee_principal_id = pr.principal_id
    LEFT JOIN sys.objects o ON p.major_id = o.object_id
    LEFT JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE pr.name = 'admindb';
    "
    
    log "INFO" "Checking database-level user status..."
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "$db_check_sql" -s"|" -W -t 30
}
# Enhanced fix function
fix_admindb_user() {
    log "INFO" "=== FIXING ADMINDB USER ACCESS ==="
    
    local fix_sql="
    USE [$DB_NAME];
    
    -- First, try to drop and recreate the database user if it exists
    IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'admindb')
    BEGIN
        -- Remove from roles first
        DECLARE @role_name NVARCHAR(128)
        DECLARE role_cursor CURSOR FOR
        SELECT r.name 
        FROM sys.database_role_members rm
        JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
        JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
        WHERE u.name = 'admindb'
        
        OPEN role_cursor
        FETCH NEXT FROM role_cursor INTO @role_name
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC sp_droprolemember @role_name, 'admindb'
            PRINT 'Removed admindb from role: ' + @role_name
            FETCH NEXT FROM role_cursor INTO @role_name
        END
        CLOSE role_cursor
        DEALLOCATE role_cursor
        
        -- Drop the user
        DROP USER [admindb]
        PRINT 'Dropped existing database user: admindb'
    END
    
    -- Recreate the user with proper mapping
    CREATE USER [admindb] FOR LOGIN [admindb]
    PRINT 'Created database user: admindb'
    
    -- Add to the application role
    ALTER ROLE db_application_role ADD MEMBER [admindb]
    PRINT 'Added admindb to db_application_role'
    
    -- Grant additional permissions if needed
    GRANT CONNECT TO [admindb]
    PRINT 'Granted CONNECT permission to admindb'
    
    SELECT 'ADMINDB_FIXED' as Status
    "
    
    if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "$fix_sql" -t 60 | grep -q "ADMINDB_FIXED"; then
        log "SUCCESS" "admindb user has been fixed"
        
        # Test the fix
        log "INFO" "Testing admindb access after fix..."
        if /opt/mssql-tools/bin/sqlcmd -S localhost -U admindb -P "$DB_APP_PASSWORD" \
            -d "$DB_NAME" -Q "SELECT COUNT(*) as TableCount FROM INFORMATION_SCHEMA.TABLES" -h-1 -W -t 30 2>/dev/null; then
            log "SUCCESS" "✓ admindb can now access the database"
        else
            log "ERROR" "✗ admindb still cannot access the database"
        fi
    else
        log "ERROR" "Failed to fix admindb user"
    fi
}
check_orphaned_users() {
    log "INFO" "=== CHECKING FOR ORPHANED USERS ==="
    
    local orphan_sql="
    USE [$DB_NAME];
    
    SELECT 
        'ORPHANED_USER' as CheckType,
        dp.name as UserName,
        dp.type_desc as UserType,
        CASE WHEN dp.sid IS NULL OR sp.sid IS NULL THEN 'ORPHANED' ELSE 'MAPPED' END as Status
    FROM sys.database_principals dp
    LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid
    WHERE dp.type IN ('S', 'U') 
        AND dp.principal_id > 4
        AND dp.name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys')
        AND dp.name IN ('admindb', 'BBTDev', 'BBTAdmin')
    ORDER BY dp.name
    "
    
    /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "$orphan_sql" -s"|" -W -t 30
}
fix_orphaned_admindb_remap() {
    log "INFO" "Attempting to remap orphaned admindb user..."
    
    local remap_sql="
    USE [$DB_NAME];
    
    -- Use sp_change_users_login to remap the orphaned user
    EXEC sp_change_users_login 'Update_One', 'admindb', 'admindb';
    
    SELECT 'REMAP_COMPLETE' as Status;
    "
    
    if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -Q "$remap_sql" -t 30 2>/dev/null | grep -q "REMAP_COMPLETE"; then
        log "SUCCESS" "User remapping completed"
        return 0
    else
        log "WARNING" "Remapping failed, trying recreation method..."
        return 1
    fi
}
# fix_orphaned_admindb_recreate() {
#     log "INFO" "Recreating admindb user with proper mapping..."
    
#     local recreate_sql="
#     USE [$DB_NAME];
    
#     -- Store current role memberships
#     DECLARE @roles TABLE (role_name NVARCHAR(128));
#     INSERT INTO @roles (role_name)
#     SELECT r.name 
#     FROM sys.database_role_members rm
#     JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
#     JOIN sys.database_principals u ON rm.member_principal_id = u.principal_id
#     WHERE u.name = 'admindb' AND r.name NOT IN ('public');
    
#     -- Drop the orphaned user
#     IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'admindb')
#     BEGIN
#         DROP USER [admindb];
#         PRINT 'Dropped orphaned user: admindb';
#     END
    
#     -- Recreate user with proper login mapping
#     CREATE USER [admindb] FOR LOGIN [admindb];
#     PRINT 'Created user: admindb with proper login mapping';
    
#     -- Restore role memberships
#     DECLARE @role_name NVARCHAR(128);
#     DECLARE role_cursor CURSOR FOR SELECT role_name FROM @roles;
#     OPEN role_cursor;
#     FETCH NEXT FROM role_cursor INTO @role_name;
#     WHILE @@FETCH_STATUS = 0
#     BEGIN
#         EXEC sp_addrolemember @role_name, 'admindb';
#         PRINT 'Added admindb to role: ' + @role_name;
#         FETCH NEXT FROM role_cursor INTO @role_name;
#     END
#     CLOSE role_cursor;
#     DEALLOCATE role_cursor;
    
#     -- Ensure CONNECT permission
#     GRANT CONNECT TO [admindb];
#     PRINT 'Granted CONNECT permission';
    
#     SELECT 'RECREATE_COMPLETE' as Status;
#     "
    
#     if /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
#         -Q "$recreate_sql" -t 60 | grep -q "RECREATE_COMPLETE"; then
#         log "SUCCESS" "User recreation completed"
#         return 0
#     else
#         log "ERROR" "User recreation failed"
#         return 1
#     fi
# }
# fix_admindb_orphaned_user() {
#     log "INFO" "=== FIXING ORPHANED ADMINDB USER ==="
    
#     # Try remapping first (preserves user history)
#     if fix_orphaned_admindb_remap; then
#         log "SUCCESS" "Fixed using remap method"
#     else
#         # Fall back to recreation
#         if fix_orphaned_admindb_recreate; then
#             log "SUCCESS" "Fixed using recreation method"
#         else
#             log "ERROR" "All fix methods failed"
#             return 1
#         fi
#     fi
    
#     # Test the fix
#     log "INFO" "Testing admindb access after fix..."
#     local test_result
#     if test_result=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U admindb -P "$DB_APP1_PASSWORD" \
#         -d "$DB_NAME" -Q "SELECT COUNT(*) as TableCount FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'" -h-1 -W -t 30 2>&1); then
        
#         local table_count=$(echo "$test_result" | tr -d ' \n\r' | sed 's/[^0-9]//g')
#         log "SUCCESS" "✓ admindb can now access database (sees $table_count tables)"
        
#         # Verify user mapping is now correct
#         verify_user_mapping_fixed
        
#     else
#         log "ERROR" "✗ admindb still cannot access database after fix"
#         echo "$test_result" | head -3 | while IFS= read -r line; do
#             [[ -n "$line" ]] && log "ERROR" "    $line"
#         done
#         return 1
#     fi
# }
verify_user_access() {
    log "INFO" "=== VERIFYING USER ACCESS AND PERMISSIONS ==="
    
    local verification_sql="
    USE [$DB_NAME];
    
    -- Check database users and their roles
    SELECT 
        'USER_ROLES' as CheckType,
        dp.name as PrincipalName,
        dp.type_desc as PrincipalType,
        r.name as RoleName,
        CASE WHEN r.name IS NULL THEN 'No Role Membership' ELSE 'Role Member' END as Status
    FROM sys.database_principals dp
    LEFT JOIN sys.database_role_members rm ON dp.principal_id = rm.member_principal_id
    LEFT JOIN sys.database_principals r ON rm.role_principal_id = r.principal_id
    WHERE dp.type IN ('S', 'U') -- SQL users and Windows users
        AND dp.principal_id > 4 -- Exclude system users
        AND dp.name NOT IN ('guest', 'INFORMATION_SCHEMA', 'sys')
    ORDER BY dp.name, r.name;
    
    -- Check specific permissions for custom roles
    SELECT 
        'ROLE_PERMISSIONS' as CheckType,
        p.permission_name,
        p.state_desc as PermissionState,
        pr.name as RoleName,
        ISNULL(s.name, 'DATABASE') as SchemaName,
        ISNULL(o.name, 'N/A') as ObjectName
    FROM sys.database_permissions p
    LEFT JOIN sys.objects o ON p.major_id = o.object_id
    LEFT JOIN sys.schemas s ON o.schema_id = s.schema_id
    LEFT JOIN sys.database_principals pr ON p.grantee_principal_id = pr.principal_id
    WHERE pr.name IN ('db_reader_role', 'db_executor_role', 'db_application_role')
    ORDER BY pr.name, p.permission_name;
    
    SELECT 'ACCESS_CHECK_COMPLETED' as Status;
    "
    
    log "INFO" "Executing user access verification..."
    
    local verification_output
    if verification_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$SA_PASSWORD" \
        -d "$DB_NAME" -Q "$verification_sql" -s"|" -W -t 60 2>&1); then
        
        if echo "$verification_output" | grep -q "ACCESS_CHECK_COMPLETED"; then
            log "SUCCESS" "User access verification completed"
            
            # Parse and display results
            log "INFO" "=== USER ROLE MEMBERSHIPS ==="
            echo "$verification_output" | grep "^USER_ROLES|" | while IFS='|' read -r checktype username usertype rolename status; do
                log "INFO" "User: $username ($usertype) -> Role: ${rolename:-'None'} ($status)"
            done
            
            log "INFO" "=== ROLE PERMISSIONS ==="
            echo "$verification_output" | grep "^ROLE_PERMISSIONS|" | while IFS='|' read -r checktype permission state role schema object; do
                log "INFO" "Role: $role -> Permission: $permission ($state) on ${schema}.${object}"
            done
            
            # Test actual access for each user with proper password mapping
            log "INFO" "=== TESTING USER ACCESS ==="
            
            # Define user-password pairs explicitly
            declare -A user_passwords
            user_passwords["${DB_READ_USER:-BBTDev}"]="${DB_READ_PASSWORD}"
            user_passwords["${DB_EXECUTE_USER:-BBTAdmin}"]="${DB_EXECUTE_PASSWORD}"
            user_passwords["${DB_APP_USER:-admindb}"]="${DB_APP_PASSWORD}"
            
            # Test each user individually
            for username in "${!user_passwords[@]}"; do
                local user_password="${user_passwords[$username]}"
                
                if [[ -n "$username" && -n "$user_password" ]]; then
                    log "INFO" "Testing access for user: $username"
                    log "DEBUG" "Using password length: ${#user_password} characters"
                    
                    # Test basic SELECT access with proper password
                    local test_result
                    if test_result=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U "$username" -P "$user_password" \
                        -d "$DB_NAME" -Q "SELECT COUNT(*) as TableCount FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'" -h-1 -W -t 30 2>&1); then
                        
                        local table_count=$(echo "$test_result" | tr -d ' \n\r' | sed 's/[^0-9]//g')
                        log "SUCCESS" "✓ User $username can access database (sees $table_count tables)"
                        
                        # Additional test - check if user can perform expected operations
                        test_user_specific_permissions "$username" "$user_password"
                        
                    else
                        log "ERROR" "✗ User $username cannot access database"
                        echo "$test_result" | head -3 | while IFS= read -r line; do
                            [[ -n "$line" ]] && log "ERROR" "    $line"
                        done
                        
                        # Try to diagnose the issue
                        diagnose_user_login_issue "$username"
                    fi
                else
                    if [[ -z "$username" ]]; then
                        log "WARNING" "⚠ Username is empty, skipping test"
                    elif [[ -z "$user_password" ]]; then
                        log "WARNING" "⚠ Password for user '$username' is not set, skipping test"
                    fi
                fi
            done
            
        else
            log "WARNING" "User access verification completed with warnings"
            echo "$verification_output" | tail -10 | while IFS= read -r line; do
                [[ -n "$line" ]] && log "WARNING" "  $line"
            done
        fi
    else
        log "ERROR" "Failed to execute user access verification"
        echo "$verification_output" | while IFS= read -r line; do
            [[ -n "$line" ]] && log "ERROR" "  $line"
        done
        return 1
    fi
    
    log "INFO" "=== END USER ACCESS VERIFICATION ==="
}

# Main execution function
main() {
    log "INFO" "Starting PRODUCTION-SAFE database initialization process..."
    log "INFO" "This script is designed for Windows to Linux migration with data preservation"
    
    # Initialize execution tracking
    echo "=== Database Initialization Started: $(date) ===" > /var/opt/mssql/data/.script_execution_log
    
    # Clear any previous failure markers if requested
    if [[ "${CLEAR_FAILED_SCRIPTS:-false}" == "true" ]]; then
        rm -f /var/opt/mssql/data/.failed_scripts
        log "INFO" "Cleared previous script failure markers"
    fi
    
    # Ensure required directories exist with proper permissions
    mkdir -p /var/opt/mssql/{data,log,backup,logs,scripts}
    chown -R mssql:root /var/opt/mssql/
    chmod -R 755 /var/opt/mssql/
    
    # Enhanced debug: Show actual directory structure with file counts
    log "DEBUG" "=== DIRECTORY STRUCTURE ANALYSIS ==="
    if [[ -d "/var/opt/mssql/scripts" ]]; then
        find /var/opt/mssql/scripts -type d 2>/dev/null | while IFS= read -r dir; do
            local file_count=$(find "$dir" -maxdepth 1 -name "*.sql" -type f 2>/dev/null | wc -l)
            log "DEBUG" "Directory: $dir ($file_count SQL files)"
            
            if [[ $file_count -gt 0 && $file_count -le 5 ]]; then
                # Show first few files for small directories
                find "$dir" -maxdepth 1 -name "*.sql" -type f 2>/dev/null | head -3 | while IFS= read -r file; do
                    log "DEBUG" "  - $(basename "$file")"
                done
            elif [[ $file_count -gt 5 ]]; then
                # Show sample files for large directories
                log "DEBUG" "  - Sample files:"
                find "$dir" -maxdepth 1 -name "*.sql" -type f 2>/dev/null | head -2 | while IFS= read -r file; do
                    log "DEBUG" "    * $(basename "$file")"
                done
                log "DEBUG" "    * ... and $((file_count - 2)) more files"
            fi
        done
    else
        log "WARNING" "Scripts directory not found: /var/opt/mssql/scripts"
    fi
    
    # Start SQL Server
    start_sql_server
    
    # Wait for SQL Server to be ready
    if ! wait_for_sql_server; then
        log "ERROR" "SQL Server failed to start - cannot continue"
        exit 1
    fi
    
    # STEP 1: Initialize/restore database safely
    if ! initialize_database_safely; then
        log "ERROR" "Database initialization failed - cannot continue"
        exit 1
    fi
    
    # STEP 2: Create database users (only if needed)
    create_database_users
    
    # STEP 3: Verify user access before script execution
    verify_user_access
    
    # STEP 4: Execute SQL scripts using enhanced dedicated script executor
    log "INFO" "=== STARTING ENHANCED SQL SCRIPT EXECUTION PHASE ==="
    
    # Path to the enhanced SQL script executor
    local sql_executor_script="/var/opt/mssql/execute-sql-scripts.sh"
    
    # Ensure the enhanced executor is available
    if [[ ! -f "$sql_executor_script" ]]; then
        log "WARNING" "Enhanced SQL executor not found at: $sql_executor_script"
        log "INFO" "Creating enhanced executor script..."
        
        # Create the enhanced executor if it doesn't exist
        # (Assuming the enhanced script content is available)
        if [[ -f "/opt/src/db/execute-sql-scripts-enhanced.sh" ]]; then
            cp "/opt/src/db/execute-sql-scripts-enhanced.sh" "$sql_executor_script"
            chmod +x "$sql_executor_script"
            chown mssql:root "$sql_executor_script"
            log "SUCCESS" "Enhanced SQL executor deployed successfully"
        else
            log "ERROR" "Enhanced SQL executor source not found"
            log "ERROR" "Please ensure the enhanced script is available"
            exit 1
        fi
    fi
    
    if [[ -f "$sql_executor_script" && -x "$sql_executor_script" ]]; then
        log "INFO" "Using enhanced SQL script executor: $sql_executor_script"
        
        # Set comprehensive environment variables for the executor
        export DB_SERVER="${DB_SERVER:-localhost}"
        export DB_NAME="${DB_NAME:-AdminDB}"
        export SA_PASSWORD="${SA_PASSWORD}"
        export SCRIPTS_BASE_PATH="${SCRIPTS_BASE_PATH:-/var/opt/mssql/scripts}"
        export LOG_BASE_PATH="${LOG_BASE_PATH:-/var/opt/mssql/logs}"
        export DATA_PATH="${DATA_PATH:-/var/opt/mssql/data}"
        export MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-3}"
        export RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-2}"
        export CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-true}"
        export FORCE_RECREATE="${FORCE_RECREATE:-false}"
        
        # Show pre-execution summary
        log "INFO" "=== PRE-EXECUTION SUMMARY ==="
        
        # Quick script count check
        local total_scripts=0
        for folder in functions tables procedures base-data; do
            local folder_path="$SCRIPTS_BASE_PATH/$folder"
            if [[ -d "$folder_path" ]]; then
                local count=$(find "$folder_path" -maxdepth 1 -name "*.sql" -type f 2>/dev/null | wc -l)
                log "INFO" "  - $folder: $count SQL files"
                total_scripts=$((total_scripts + count))
            else
                log "WARNING" "  - $folder: directory not found"
            fi
        done
        
        log "INFO" "Total SQL files discovered: $total_scripts"
        
        # Execute the SQL scripts using the enhanced executor
        local executor_start_time=$(date +%s)
        
        if "$sql_executor_script"; then
            local executor_end_time=$(date +%s)
            local executor_duration=$((executor_end_time - executor_start_time))
            
            log "SUCCESS" "Enhanced SQL script executor completed successfully in ${executor_duration}s"
            
            # Parse execution results from the executor's tracker
            local tracker_file="$DATA_PATH/.sql_execution_tracker"
            if [[ -f "$tracker_file" ]]; then
                local successful_count=$(grep -c "^SUCCESS" "$tracker_file" 2>/dev/null || echo "0")
                local failed_count=$(grep -c "^FAILED" "$tracker_file" 2>/dev/null || echo "0")
                
                log "INFO" "Execution Results Summary:"
                log "INFO" "  - Successful: $successful_count"
                log "INFO" "  - Failed: $failed_count"
                
                if [[ $failed_count -gt 0 ]]; then
                    log "WARNING" "Some scripts failed - check logs for details"
                    
                    # Show failed script details
                    log "WARNING" "Failed scripts:"
                    grep "^FAILED" "$tracker_file" 2>/dev/null | head -5 | while IFS='|' read -r status folder script_name exec_time retry_count error_msg; do
                        log "WARNING" "  - [$folder] $script_name: $(echo "$error_msg" | cut -c1-80)..."
                    done || true
                    
                    if [[ $failed_count -gt 5 ]]; then
                        log "WARNING" "  ... and $((failed_count - 5)) more (see tracker file for complete list)"
                    fi
                fi
            fi
            
        else
            local executor_exit_code=$?
            local executor_end_time=$(date +%s)
            local executor_duration=$((executor_end_time - executor_start_time))
            
            log "ERROR" "Enhanced SQL script executor failed with exit code: $executor_exit_code (after ${executor_duration}s)"
            
            # Enhanced error analysis
            log "ERROR" "=== FAILURE ANALYSIS ==="
            
            # Check the most recent error log
            local latest_error_log=$(find "$LOG_BASE_PATH" -name "sql-errors-*.log" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
            
            if [[ -n "$latest_error_log" && -f "$latest_error_log" ]]; then
                log "ERROR" "Latest error log: $latest_error_log"
                log "ERROR" "Recent errors:"
                tail -10 "$latest_error_log" 2>/dev/null | while IFS= read -r error_line; do
                    log "ERROR" "  $error_line"
                done || true
            fi
            
            # Check for common failure patterns
            if grep -q "Script file not found" "$latest_error_log" 2>/dev/null; then
                log "ERROR" "Root cause: Script file discovery issues detected"
                log "ERROR" "Recommendation: Check script file paths and permissions"
            fi
            
            if grep -q "There is already an object named" "$latest_error_log" 2>/dev/null; then
                log "ERROR" "Root cause: Object already exists errors detected"
                log "ERROR" "Recommendation: Set FORCE_RECREATE=true or add problematic scripts to exclusions"
            fi
            
            # Decision logic for continuing
            if [[ "${CONTINUE_ON_ERROR:-true}" == "true" ]]; then
                log "WARNING" "Continuing initialization despite script execution failures"
                log "WARNING" "Database may be partially initialized - manual intervention may be required"
            else
                log "ERROR" "Stopping initialization due to script execution failure"
                exit $executor_exit_code
            fi
        fi
    else
        log "ERROR" "Enhanced SQL script executor not found and could not be created"
        log "ERROR" "Expected location: $sql_executor_script"
        
        # Emergency fallback with basic execution
        log "WARNING" "Falling back to emergency basic execution mode"
        
        # Use basic execution with error handling
        local emergency_success=true
        
        for folder in functions tables procedures base-data; do
            local folder_path="/var/opt/mssql/scripts/$folder"
            if [[ -d "$folder_path" ]]; then
                log "INFO" "Emergency execution for folder: $folder"
                if ! execute_basic_scripts_in_folder "$folder_path" "$folder"; then
                    emergency_success=false
                    if [[ "${CONTINUE_ON_ERROR:-true}" != "true" ]]; then
                        break
                    fi
                fi
            fi
        done
        
        if [[ "$emergency_success" != "true" ]]; then
            log "ERROR" "Emergency execution completed with errors"
        fi
    fi
    
    log "INFO" "=== SQL SCRIPT EXECUTION PHASE COMPLETED ==="
    
    # STEP 5: Apply final permissions
    apply_post_script_permissions
    
    # STEP 6: Create comprehensive success marker
    touch /var/opt/mssql/data/.initialized
    echo "$(date): Database initialization/update completed" >> /var/opt/mssql/data/.initialization_log
    echo "=== Database Initialization Completed: $(date) ===" >> /var/opt/mssql/data/.script_execution_log
    
    # STEP 7: Generate final verification report
    generate_final_verification_report
    
    # STEP 8: Database server ready
    log "INFO" "Database server is ready and running. Waiting for connections..."
    wait $SERVER_PID
}
execute_basic_scripts_in_folder() {
    local folder_path="$1"
    local folder_name="$2"
    
    log "INFO" "Emergency execution for folder: $folder_name"
    
    local script_count=0
    local success_count=0
    local failed_count=0
    
    while IFS= read -r script_file; do
        [[ -z "$script_file" ]] && continue
        ((script_count++))
        
        local script_name="$(basename "$script_file")"
        
        # Check exclusions in emergency mode
        local skip_script=false
        for pattern in "${EXCLUDED_FILES[@]:-}"; do
            if [[ "$script_name" == $pattern ]]; then
                log "INFO" "Skipping excluded script: $script_name"
                skip_script=true
                break
            fi
        done
        
        [[ "$skip_script" == "true" ]] && continue
        
        log "INFO" "Executing: $script_name"
        
        if /opt/mssql-tools/bin/sqlcmd -S "$DB_SERVER" -U sa -P "$SA_PASSWORD" -d "$DB_NAME" \
            -i "$script_file" -b -t 30 >/dev/null 2>&1; then
            ((success_count++))
            log "SUCCESS" "  - $script_name executed successfully"
        else
            ((failed_count++))
            log "ERROR" "  - $script_name execution failed"
        fi
        
    done < <(find "$folder_path" -maxdepth 1 -name "*.sql" -type f | sort -V)
    
    log "INFO" "Emergency execution summary for $folder_name:"
    log "INFO" "  - Processed: $script_count scripts"
    log "INFO" "  - Successful: $success_count"
    log "INFO" "  - Failed: $failed_count"
    
    return $([ $failed_count -eq 0 ] && echo 0 || echo 1)
}
generate_final_verification_report() {
    log "INFO" "=== GENERATING FINAL VERIFICATION REPORT ==="
    
    # Database connectivity and structure verification
    local verification_query="
    SELECT 
        'DATABASE_VERIFICATION' as ReportType,
        DB_NAME() as DatabaseName,
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE') as TableCount,
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_TYPE = 'FUNCTION') as FunctionCount,
        (SELECT COUNT(*) FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_TYPE = 'PROCEDURE') as ProcedureCount,
        CAST(SUM(CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint) * 8.0 / 1024 / 1024) AS DECIMAL(10,2)) as DatabaseSizeGB
    FROM sys.database_files WHERE type = 0
    "
    
    local verification_result
    if verification_result=$(/opt/mssql-tools/bin/sqlcmd -S "$DB_SERVER" -U sa -P "$SA_PASSWORD" -d "$DB_NAME" \
        -Q "$verification_query" -h-1 -s"|" -W -t 30 2>/dev/null); then
        
        # Parse verification results
        local db_name=$(echo "$verification_result" | cut -d'|' -f2 | tr -d ' ')
        local table_count=$(echo "$verification_result" | cut -d'|' -f3 | tr -d ' ')
        local function_count=$(echo "$verification_result" | cut -d'|' -f4 | tr -d ' ')
        local procedure_count=$(echo "$verification_result" | cut -d'|' -f5 | tr -d ' ')
        local db_size=$(echo "$verification_result" | cut -d'|' -f6 | tr -d ' ')
        
        log "SUCCESS" "=== DATABASE VERIFICATION RESULTS ==="
        log "SUCCESS" "Database: $db_name"
        log "SUCCESS" "Tables: $table_count"
        log "SUCCESS" "Functions: $function_count"
        log "SUCCESS" "Procedures: $procedure_count"
        log "SUCCESS" "Database Size: ${db_size}GB"
        
        # Consolidate execution statistics
        local total_executed=0
        local total_successful=0
        local total_failed=0
        local total_excluded=0
        
        # Check both old and new execution tracking
        if [[ -f "/var/opt/mssql/data/.sql_execution_tracker" ]]; then
            total_executed=$(grep -c "SUCCESS\|FAILED" "/var/opt/mssql/data/.sql_execution_tracker" 2>/dev/null || echo "0")
            total_successful=$(grep -c "^SUCCESS" "/var/opt/mssql/data/.sql_execution_tracker" 2>/dev/null || echo "0")
            total_failed=$(grep -c "^FAILED" "/var/opt/mssql/data/.sql_execution_tracker" 2>/dev/null || echo "0")
        fi
        
        if [[ -f "/var/opt/mssql/logs/excluded-scripts-"*".log" ]]; then
            total_excluded=$(find /var/opt/mssql/logs -name "excluded-scripts-*.log" -exec cat {} \; 2>/dev/null | grep -c "EXCLUDED" || echo "0")
        fi
        
        log "SUCCESS" "=== SCRIPT EXECUTION SUMMARY ==="
        log "SUCCESS" "Scripts Executed: $total_executed"
        log "SUCCESS" "Successful: $total_successful"
        if [[ $total_failed -gt 0 ]]; then
            log "WARNING" "Failed: $total_failed"
        else
            log "SUCCESS" "Failed: $total_failed"
        fi
        log "INFO" "Excluded: $total_excluded"
        
        # Calculate and display success rate
        if [[ $total_executed -gt 0 ]]; then
            local success_rate=$(( total_successful * 100 / total_executed ))
            log "SUCCESS" "Success Rate: ${success_rate}%"
        fi
        
        # List available log files for troubleshooting
        log "INFO" "=== AVAILABLE LOG FILES ==="
        find /var/opt/mssql/logs -name "*.log" -o -name "*.log.gz" 2>/dev/null | sort | while read -r logfile; do
            local file_size=$(ls -lh "$logfile" 2>/dev/null | awk '{print $5}' || echo "Unknown")
            log "INFO" "  - $(basename "$logfile"): $file_size"
        done || true
        
        # Final status determination
        if [[ $total_failed -eq 0 || "${CONTINUE_ON_ERROR:-true}" == "true" ]]; then
            log "SUCCESS" "=== INITIALIZATION COMPLETED SUCCESSFULLY ==="
        else
            log "ERROR" "=== INITIALIZATION COMPLETED WITH ERRORS ==="
        fi
        
    else
        log "WARNING" "Database initialization completed but final verification failed"
        log "WARNING" "Database may be partially ready - manual verification recommended"
    fi
}
# Enhanced signal handling
trap cleanup SIGTERM SIGINT SIGQUIT

# Validate required environment variables
if [[ -z "$SA_PASSWORD" ]]; then
    log "ERROR" "SA_PASSWORD environment variable is required"
    exit 1
fi

if [[ -z "$DB_NAME" ]]; then
    log "ERROR" "DB_NAME environment variable is required"
    exit 1
fi

main