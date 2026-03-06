#!/bin/bash

# Enhanced health check script for SQL Server container
# This script performs comprehensive health checks with proper timeout handling

# Set strict error handling
set -euo pipefail

# Configuration
readonly HEALTH_TIMEOUT=25
readonly SA_PASSWORD="${SA_PASSWORD}"
readonly DB_NAME="${DB_NAME}"
readonly LOG_FILE="/var/opt/mssql/log/healthcheck.log"

# Logging function
log_health() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $level: $message" >> "$LOG_FILE" 2>/dev/null || true
    echo "[$timestamp] $level: $message" >&2
}

# Function to check if SQL Server process is running
check_sql_process() {
    if pgrep -f "sqlservr" > /dev/null 2>&1; then
        return 0
    else
        log_health "ERROR" "SQL Server process not found"
        return 1
    fi
}

# Function to check SQL Server connectivity
check_sql_connectivity() {
    local timeout=15
    
    if timeout $timeout /opt/mssql-tools/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$SA_PASSWORD" \
        -Q "SELECT 1 as health_check" \
        -h -1 > /dev/null 2>&1; then
        return 0
    else
        log_health "ERROR" "SQL Server connectivity check failed"
        return 1
    fi
}

# Function to check database accessibility
check_database_access() {
    local timeout=15
    
    # Skip database check if DB_NAME is not set or empty
    if [[ -z "${DB_NAME:-}" ]]; then
        log_health "INFO" "DB_NAME not set, skipping database access check"
        return 0
    fi
    
    # Check if database exists first
    local db_exists
    if ! db_exists=$(timeout $timeout /opt/mssql-tools/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$SA_PASSWORD" \
        -h -1 \
        -Q "SELECT COUNT(*) FROM sys.databases WHERE name = '$DB_NAME'" 2>/dev/null | tr -d ' \n\r'); then
        log_health "ERROR" "Failed to check database existence"
        return 1
    fi
    
    if [[ "$db_exists" != "1" ]]; then
        log_health "WARNING" "Database '$DB_NAME' does not exist"
        return 1
    fi
    
    # Check database accessibility
    if timeout $timeout /opt/mssql-tools/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$SA_PASSWORD" \
        -d "$DB_NAME" \
        -Q "SELECT 1 as db_health_check" \
        -h -1 > /dev/null 2>&1; then
        return 0
    else
        log_health "ERROR" "Database '$DB_NAME' accessibility check failed"
        return 1
    fi
}

# Function to check SQL Server system health
check_sql_system_health() {
    local timeout=10
    
    # Check for blocking processes or long-running transactions
    local health_info
    if health_info=$(timeout $timeout /opt/mssql-tools/bin/sqlcmd \
        -S localhost \
        -U sa \
        -P "$SA_PASSWORD" \
        -h -1 \
        -Q "
        SELECT 
            CASE 
                WHEN COUNT(*) > 0 THEN 'BLOCKING_DETECTED'
                ELSE 'HEALTHY'
            END as blocking_status
        FROM sys.dm_exec_requests 
        WHERE blocking_session_id > 0 AND wait_time > 30000
        " 2>/dev/null | tr -d ' \n\r'); then
        
        if [[ "$health_info" == "BLOCKING_DETECTED" ]]; then
            log_health "WARNING" "Blocking processes detected"
            # Don't fail health check for blocking, just log it
        fi
        return 0
    else
        log_health "WARNING" "Failed to check system health metrics"
        return 0  # Don't fail health check for this
    fi
}

# Function to check disk space
check_disk_space() {
    # Check available space in data directory (fail if less than 100MB)
    local data_space
    if data_space=$(df /var/opt/mssql/data 2>/dev/null | awk 'NR==2 {print $4}'); then
        if [[ "$data_space" -lt 102400 ]]; then  # Less than 100MB in KB
            log_health "ERROR" "Low disk space in data directory: ${data_space}KB available"
            return 1
        fi
    fi
    
    # Check available space in log directory
    local log_space
    if log_space=$(df /var/opt/mssql/log 2>/dev/null | awk 'NR==2 {print $4}'); then
        if [[ "$log_space" -lt 51200 ]]; then  # Less than 50MB in KB
            log_health "WARNING" "Low disk space in log directory: ${log_space}KB available"
            # Don't fail for log space, just warn
        fi
    fi
    
    return 0
}

# Function to check initialization status
check_initialization_status() {
    # If initialization marker exists, we're good
    if [[ -f "/var/opt/mssql/data/.initialized" ]]; then
        return 0
    fi
    
    # If we're still in startup phase (within first 5 minutes), be more lenient
    local container_age
    if container_age=$(stat -c %Y /proc/1 2>/dev/null); then
        local current_time=$(date +%s)
        local startup_duration=$((current_time - container_age))
        
        if [[ $startup_duration -lt 300 ]]; then  # Less than 5 minutes
            log_health "INFO" "Container still in startup phase (${startup_duration}s), initialization may be ongoing"
            return 0
        else
            log_health "WARNING" "Container running for ${startup_duration}s but initialization not complete"
            return 1
        fi
    fi
    
    return 1
}

# Main health check function
main() {
    local health_status=0
    local checks_passed=0
    local total_checks=6
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    
    log_health "INFO" "Starting comprehensive health check"
    
    # Check 1: SQL Server process
    if check_sql_process; then
        log_health "SUCCESS" "SQL Server process is running"
        ((checks_passed++))
    else
        health_status=1
    fi
    
    # Check 2: SQL Server connectivity
    if check_sql_connectivity; then
        log_health "SUCCESS" "SQL Server connectivity OK"
        ((checks_passed++))
    else
        health_status=1
    fi
    
    # Check 3: Database accessibility (if applicable)
    if check_database_access; then
        log_health "SUCCESS" "Database access OK"
        ((checks_passed++))
    else
        # For database access, we might be more lenient during startup
        if check_initialization_status; then
            log_health "INFO" "Database access failed but initialization may be ongoing"
            ((checks_passed++))
        else
            health_status=1
        fi
    fi
    
    # Check 4: System health
    if check_sql_system_health; then
        log_health "SUCCESS" "SQL Server system health OK"
        ((checks_passed++))
    else
        # System health failure is not critical
        log_health "WARNING" "System health check had issues but not critical"
        ((checks_passed++))
    fi
    
    # Check 5: Disk space
    if check_disk_space; then
        log_health "SUCCESS" "Disk space OK"
        ((checks_passed++))
    else
        health_status=1
    fi
    
    # Check 6: Initialization status
    if check_initialization_status; then
        log_health "SUCCESS" "Initialization status OK"
        ((checks_passed++))
    else
        # During extended restore operations, this might be expected
        local restore_active
        if restore_active=$(/opt/mssql-tools/bin/sqlcmd \
            -S localhost \
            -U sa \
            -P "$SA_PASSWORD" \
            -h -1 \
            -Q "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE command LIKE '%RESTORE%'" 2>/dev/null | tr -d ' \n\r'); then
            
            if [[ "$restore_active" -gt "0" ]]; then
                log_health "INFO" "Initialization incomplete but restore operation is active"
                ((checks_passed++))
            else
                health_status=1
            fi
        else
            health_status=1
        fi
    fi
    
    # Summary
    log_health "INFO" "Health check completed: $checks_passed/$total_checks checks passed"
    
    if [[ $health_status -eq 0 ]]; then
        log_health "SUCCESS" "Container is healthy"
        exit 0
    else
        log_health "ERROR" "Container health check failed"
        
        # Show recent error log entries for debugging
        if [[ -f "/var/opt/mssql/log/errorlog" ]]; then
            log_health "INFO" "Recent SQL Server errors:"
            tail -5 /var/opt/mssql/log/errorlog 2>/dev/null | while read line; do
                log_health "ERROR" "ERRORLOG: $line"
            done
        fi
        
        exit 1
    fi
}

# Timeout wrapper for entire health check
timeout $HEALTH_TIMEOUT bash -c 'main "$@"' -- "$@" 2>&1