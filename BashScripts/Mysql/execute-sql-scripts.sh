#!/bin/bash

# =============================================================================
# Enhanced SQL Script Execution Engine for Production Database Deployment
# =============================================================================
# Purpose: Execute SQL scripts with comprehensive error handling and exclusions
# Features: File exclusions, dependency handling, detailed logging, retry logic
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION AND GLOBAL VARIABLES
# =============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXECUTION_START_TIME="$(date '+%Y%m%d_%H%M%S')"

# Database configuration
readonly DB_SERVER="${DB_SERVER:-localhost}"
readonly DB_NAME="${DB_NAME:-AdminDB}"
readonly SA_PASSWORD="${SA_PASSWORD:-YourStrong!Passw0rd}"
readonly DB_TIMEOUT="${DB_TIMEOUT:-300}"

# Script execution paths
readonly SCRIPTS_BASE_PATH="${SCRIPTS_BASE_PATH:-/var/opt/mssql/scripts}"
readonly LOG_BASE_PATH="${LOG_BASE_PATH:-/var/opt/mssql/logs}"
readonly DATA_PATH="${DATA_PATH:-/var/opt/mssql/data}"

# Execution configuration
readonly MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-5}"
readonly RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-3}"
readonly RETRY_DELAY="${RETRY_DELAY:-5}"
readonly CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-true}"
readonly FORCE_RECREATE="${FORCE_RECREATE:-false}"

# Log files
readonly MAIN_LOG_FILE="$LOG_BASE_PATH/sql-execution-${EXECUTION_START_TIME}.log"
readonly ERROR_LOG_FILE="$LOG_BASE_PATH/sql-errors-${EXECUTION_START_TIME}.log"
readonly SUMMARY_LOG_FILE="$LOG_BASE_PATH/sql-summary-${EXECUTION_START_TIME}.log"
readonly EXECUTION_TRACKER="$DATA_PATH/.sql_execution_tracker"
readonly EXCLUDED_SCRIPTS_LOG="$LOG_BASE_PATH/excluded-scripts-${EXECUTION_START_TIME}.log"

# =============================================================================
# SCRIPT EXCLUSION CONFIGURATION
# =============================================================================

# Files to exclude from execution (patterns supported)
readonly EXCLUDED_FILES=(
    "dbo.fun_DaysCalculation.UserDefinedFunction.sql"
    "*.backup.sql"
    "*.old.sql"
    "*.disabled.sql"
    "*_template.sql"
    "test_*.sql"
    "*_test.sql"
    "02App_Configuration_PROD.sql"
    "02App_Configuration_UAT.sql"
    # Add more patterns as needed
)

# Folders to exclude completely
readonly EXCLUDED_FOLDERS=(
    "archived"
    "backup"
    "templates"
    "tests"
    # Add more folder names as needed
)

# =============================================================================
# ENHANCED SCRIPT FOLDER CONFIGURATION
# =============================================================================

declare -A SCRIPT_FOLDERS=(
    ["1_functions"]="functions"
    ["2_tables"]="tables"
    ["3_procedures"]="procedures"
    ["4_basedata"]="base-data"
)

declare -A FOLDER_DESCRIPTIONS=(
    ["functions"]="Database Functions"
    ["tables"]="Database Tables and Structures"
    ["procedures"]="Stored Procedures"
    ["base-data"]="Base Data and Initial Records"
)

# Execution modes per folder
declare -A FOLDER_EXECUTION_MODES=(
    ["functions"]="parallel"
    ["tables"]="sequential"
    ["procedures"]="sequential"
    ["base-data"]="parallel"
)

# Object handling strategies
declare -A OBJECT_HANDLING=(
    ["functions"]="drop_and_create"
    ["tables"]="alter_or_create"
    ["procedures"]="drop_and_create"
    ["base-data"]="insert_or_update"
)

# Execution statistics
declare -A EXECUTION_STATS=(
    ["total_scripts"]=0
    ["successful_scripts"]=0
    ["failed_scripts"]=0
    ["skipped_scripts"]=0
    ["excluded_scripts"]=0
    ["retried_scripts"]=0
)

# =============================================================================
# ENHANCED LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local script_file="${3:-}"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Format message with script context if provided
    if [[ -n "$script_file" ]]; then
        local script_name="$(basename "$script_file")"
        local log_entry="[$timestamp] [$level] [$script_name] $message"
    else
        local log_entry="[$timestamp] [$level] $message"
    fi
    
    # Color coding for different log levels
    case "$level" in
        "ERROR")   echo -e "\033[31m$log_entry\033[0m" >&2 ;;
        "WARNING") echo -e "\033[33m$log_entry\033[0m" ;;
        "SUCCESS") echo -e "\033[32m$log_entry\033[0m" ;;
        "INFO")    echo -e "\033[36m$log_entry\033[0m" ;;
        "DEBUG")   echo -e "\033[37m$log_entry\033[0m" ;;
        "EXCLUDED") echo -e "\033[35m$log_entry\033[0m" ;;
        *)         echo "$log_entry" ;;
    esac
    
    # Always log to main log file
    echo "$log_entry" >> "$MAIN_LOG_FILE"
    
    # Log errors to separate error log
    if [[ "$level" == "ERROR" ]]; then
        echo "$log_entry" >> "$ERROR_LOG_FILE"
    fi
    
    # Log excluded files to separate log
    if [[ "$level" == "EXCLUDED" ]]; then
        echo "$log_entry" >> "$EXCLUDED_SCRIPTS_LOG"
    fi
}

create_directories() {
    log "INFO" "Creating required directory structure..."
    
    mkdir -p "$LOG_BASE_PATH"
    mkdir -p "$DATA_PATH"
    
    # Ensure proper permissions
    chown -R mssql:root "$LOG_BASE_PATH" "$DATA_PATH" 2>/dev/null || true
    chmod -R 755 "$LOG_BASE_PATH" "$DATA_PATH" 2>/dev/null || true
    
    log "SUCCESS" "Directory structure created successfully"
}

initialize_execution_tracker() {
    log "INFO" "Initializing execution tracker..."
    
    cat > "$EXECUTION_TRACKER" << EOF
# SQL Script Execution Tracker
# Format: STATUS|FOLDER|SCRIPT_NAME|EXECUTION_TIME|RETRY_COUNT|ERROR_MESSAGE
# Generated: $(date)
EOF
    
    # Initialize excluded scripts log
    cat > "$EXCLUDED_SCRIPTS_LOG" << EOF
# Excluded SQL Scripts Log
# Generated: $(date)
EOF
    
    log "SUCCESS" "Execution tracker initialized"
}

# =============================================================================
# ENHANCED SCRIPT DISCOVERY WITH EXCLUSIONS
# =============================================================================

is_script_excluded() {
    local script_file="$1"
    local script_name="$(basename "$script_file")"
    local script_dir="$(dirname "$script_file")"
    local parent_folder="$(basename "$script_dir")"
    
    # Check if parent folder is excluded
    for excluded_folder in "${EXCLUDED_FOLDERS[@]}"; do
        if [[ "$parent_folder" == "$excluded_folder" ]]; then
            log "EXCLUDED" "Folder excluded: $parent_folder" "$script_file"
            return 0
        fi
    done
    
    # Check if script matches exclusion patterns
    for pattern in "${EXCLUDED_FILES[@]}"; do
        if [[ "$script_name" == $pattern ]]; then
            log "EXCLUDED" "Script matches exclusion pattern '$pattern'" "$script_file"
            return 0
        fi
    done
    
    return 1
}

discover_scripts_in_folder() {
    local folder_path="$1"
    local folder_name="$(basename "$folder_path")"
    
    if [[ ! -d "$folder_path" ]]; then
        log "WARNING" "Script folder does not exist: $folder_path"
        return 1
    fi
    
    log "INFO" "Discovering scripts in folder: $folder_path"
    
    # Get all SQL files, sort them
    local all_scripts=()
    while IFS= read -r -d '' script_file; do
        [[ -f "$script_file" && -r "$script_file" ]] && all_scripts+=("$script_file")
    done < <(find "$folder_path" -maxdepth 1 -name "*.sql" -type f -print0 | sort -zV)
    
    if [[ ${#all_scripts[@]} -eq 0 ]]; then
        log "WARNING" "No SQL scripts found in folder: $folder_path"
        return 1
    fi
    
    # Filter excluded scripts
    local included_scripts=()
    local excluded_count=0
    
    for script_file in "${all_scripts[@]}"; do
        if is_script_excluded "$script_file"; then
            ((excluded_count++))
            ((EXECUTION_STATS["excluded_scripts"]++))
        else
            included_scripts+=("$script_file")
        fi
    done
    
    local included_count=${#included_scripts[@]}
    local total_count=${#all_scripts[@]}
    
    log "INFO" "Script discovery summary for '$folder_name':"
    log "INFO" "  - Total files found: $total_count"
    log "INFO" "  - Excluded files: $excluded_count" 
    log "INFO" "  - Files to execute: $included_count"
    
    if [[ $included_count -eq 0 ]]; then
        log "WARNING" "No executable scripts found after exclusions: $folder_path"
        return 1
    fi
    
    # Output only the script file paths
    printf '%s\n' "${included_scripts[@]}"
    return 0
}
# =============================================================================
# ENHANCED SCRIPT VALIDATION
# =============================================================================


# =============================================================================
# ENHANCED SCRIPT EXECUTION WITH OBJECT HANDLING
# =============================================================================

prepare_script_execution() {
    local script_file="$1"
    local folder_name="$2"
    local script_name="$(basename "$script_file")"
    local handling_strategy="${OBJECT_HANDLING[$folder_name]:-create_only}"
    
    # log "DEBUG" "Preparing script execution with strategy: $handling_strategy" "$script_file"
    
    case "$handling_strategy" in
        "drop_and_create")
            # Extract object name and type for functions and procedures
            if [[ "$folder_name" == "functions" || "$folder_name" == "procedures" ]]; then
                local object_name=""
                local object_type=""
                
                if [[ "$folder_name" == "functions" ]]; then
                    object_type="FUNCTION"
                    # Try to extract function name from filename or content
                    if [[ "$script_name" =~ ^dbo\.([^.]+)\. ]]; then
                        object_name="${BASH_REMATCH[1]}"
                    else
                        # Try to extract from file content
                        object_name=$(grep -oiE "CREATE\s+(OR\s+ALTER\s+)?FUNCTION\s+(\[?dbo\]?\.)?\[?([^\[\s\(]+)" "$script_file" | head -1 | sed -E 's/.*\[?([^\[\s\(]+)\]?.*/\1/')
                    fi
                elif [[ "$folder_name" == "procedures" ]]; then
                    object_type="PROCEDURE"
                    if [[ "$script_name" =~ ^dbo\.([^.]+)\. ]]; then
                        object_name="${BASH_REMATCH[1]}"
                    else
                        object_name=$(grep -oiE "CREATE\s+(OR\s+ALTER\s+)?PROC(EDURE)?\s+(\[?dbo\]?\.)?\[?([^\[\s\(]+)" "$script_file" | head -1 | sed -E 's/.*\[?([^\[\s\(]+)\]?.*/\1/')
                    fi
                fi
                
                if [[ -n "$object_name" && -n "$object_type" ]]; then
                    log "INFO" "Attempting to drop existing $object_type: $object_name" "$script_file"
                    
                    local drop_query="IF EXISTS (SELECT * FROM sys.objects WHERE name = '$object_name' AND type IN ('FN','IF','TF','P')) DROP $object_type [dbo].[$object_name]"
                    
                    /opt/mssql-tools/bin/sqlcmd -S "$DB_SERVER" -U sa -P "$SA_PASSWORD" -d "$DB_NAME" \
                        -Q "$drop_query" -b -t 30 >/dev/null 2>&1 || true
                    
                    # log "DEBUG" "Drop operation completed for $object_name" "$script_file"
                fi
            fi
            ;;
        "alter_or_create")
            # For tables, we'll let the script handle CREATE OR ALTER logic
            # log "DEBUG" "Using alter_or_create strategy - delegating to script" "$script_file"
            ;;
        "insert_or_update")
            # For base data, scripts should handle duplicate key scenarios
            # log "DEBUG" "Using insert_or_update strategy - delegating to script" "$script_file"
            ;;
    esac
}

execute_single_script() {
    local script_file="$1"
    local folder_name="$2"
    local script_name="$(basename "$script_file")"
    local retry_count="${3:-0}"
    
    # Basic file existence check only
    if [[ ! -f "$script_file" ]] || [[ ! -r "$script_file" ]]; then
        log "ERROR" "Script file not found or not readable: $script_file" "$script_file"
        echo "FAILED|$folder_name|$script_name|$(date)|$retry_count|File not accessible" >> "$EXECUTION_TRACKER"
        return 1
    fi
    
    log "INFO" "Executing script (attempt $((retry_count + 1)))" "$script_file"
    
    # Execute the script directly - no validation needed
    local execution_start=$(date +%s)
    local execution_output
    
    if execution_output=$(/opt/mssql-tools/bin/sqlcmd \
        -S "$DB_SERVER" \
        -U sa \
        -P "$SA_PASSWORD" \
        -d "$DB_NAME" \
        -i "$script_file" \
        -b \
        -t "$DB_TIMEOUT" \
        2>&1); then
        
        local execution_end=$(date +%s)
        local execution_duration=$((execution_end - execution_start))
        
        log "SUCCESS" "Script executed successfully (${execution_duration}s)" "$script_file"
        echo "SUCCESS|$folder_name|$script_name|$(date)|$retry_count|Executed in ${execution_duration}s" >> "$EXECUTION_TRACKER"
        
        ((EXECUTION_STATS["successful_scripts"]++))
        return 0
        
    else
        local execution_result=$?
        local execution_end=$(date +%s)
        local execution_duration=$((execution_end - execution_start))
        
        # Clean error message
        local clean_error=$(echo "$execution_output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-150)
        
        log "ERROR" "Script execution failed (${execution_duration}s): $clean_error" "$script_file"
        echo "FAILED|$folder_name|$script_name|$(date)|$retry_count|$clean_error" >> "$EXECUTION_TRACKER"
        
        # Simple retry logic for connection issues only
        if [[ $retry_count -lt $RETRY_ATTEMPTS ]] && echo "$execution_output" | grep -qiE "(timeout|connection|network)"; then
            log "INFO" "Retrying script after ${RETRY_DELAY}s" "$script_file"
            sleep "$RETRY_DELAY"
            ((EXECUTION_STATS["retried_scripts"]++))
            execute_single_script "$script_file" "$folder_name" $((retry_count + 1))
            return $?
        fi
        
        ((EXECUTION_STATS["failed_scripts"]++))
        return $execution_result
    fi
}

# =============================================================================
# ENHANCED FOLDER EXECUTION WITH PARALLEL/SEQUENTIAL MODES
# =============================================================================

execute_scripts_in_folder() {
    local folder_path="$1"
    local folder_name="$(basename "$folder_path")"
    local folder_description="${FOLDER_DESCRIPTIONS[$folder_name]:-$folder_name}"
    local execution_mode="${FOLDER_EXECUTION_MODES[$folder_name]:-sequential}"
    
    log "INFO" "========================================"
    log "INFO" "Starting execution: $folder_description"
    log "INFO" "Execution mode: $execution_mode"
    log "INFO" "========================================"
    
    # Get script list once
    local script_files
    if ! script_files=$(discover_scripts_in_folder "$folder_path"); then
        log "WARNING" "Skipping folder due to discovery issues: $folder_name"
        return 0
    fi
    
    local script_count=$(echo "$script_files" | wc -l)
    log "INFO" "Found $script_count scripts to execute in '$folder_name'"
    ((EXECUTION_STATS["total_scripts"] += script_count))
    
    # Execute based on mode
    if [[ "$execution_mode" == "parallel" ]]; then
        execute_scripts_parallel "$script_files" "$folder_name"
    else
        execute_scripts_sequential "$script_files" "$folder_name"
    fi
    
    log "SUCCESS" "Completed execution: $folder_description"
    return 0
}

execute_scripts_sequential() {
    local script_list="$1"
    local folder_name="$2"
    local failed_count=0
    local processed_scripts=()
    
    # Process each script exactly once
    while IFS= read -r script_file; do
        [[ -z "$script_file" ]] && continue
        [[ ! -f "$script_file" ]] && continue
        
        # Check if already processed (prevent duplicates)
        local script_name="$(basename "$script_file")"
        if [[ " ${processed_scripts[*]} " =~ " ${script_name} " ]]; then
            # log "DEBUG" "Skipping duplicate script: $script_name"
            continue
        fi
        processed_scripts+=("$script_name")
        
        if ! execute_single_script "$script_file" "$folder_name"; then
            ((failed_count++))
            if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
                log "ERROR" "Critical script failed, stopping execution: $script_name"
                return 1
            fi
        fi
        
        # Small delay between scripts
        # sleep 1
        
    done <<< "$script_list"
    
    if [[ $failed_count -gt 0 ]]; then
        log "WARNING" "Completed with $failed_count failed scripts in folder: $folder_name"
    fi
    
    return 0
}

execute_scripts_parallel() {
    local script_list="$1"
    local folder_name="$2"
    local active_jobs=0
    local pids=()
    local processed_scripts=()
    
    while IFS= read -r script_file; do
        [[ -z "$script_file" ]] && continue
        [[ ! -f "$script_file" ]] && continue
        
        # Check if already processed (prevent duplicates)
        local script_name="$(basename "$script_file")"
        if [[ " ${processed_scripts[*]} " =~ " ${script_name} " ]]; then
            # log "DEBUG" "Skipping duplicate script: $script_name"
            continue
        fi
        processed_scripts+=("$script_name")
        
        # Wait if too many parallel jobs
        while [[ $active_jobs -ge $MAX_PARALLEL_JOBS ]]; do
            # sleep 1
            local new_pids=()
            for pid in "${pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                else
                    ((active_jobs--))
                fi
            done
            pids=("${new_pids[@]}")
        done
        
        # Execute in background
        (execute_single_script "$script_file" "$folder_name") &
        local bg_pid=$!
        pids+=("$bg_pid")
        ((active_jobs++))
        
        # # Small delay to prevent resource contention
        # sleep 0.5
        
    done <<< "$script_list"
    
    # Wait for all jobs to complete
    log "INFO" "Waiting for all parallel scripts to complete in folder: $folder_name"
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
}

# =============================================================================
# ENHANCED MAIN EXECUTION WITH COMPREHENSIVE REPORTING
# =============================================================================

execute_all_scripts() {
    log "INFO" "========================================"
    log "INFO" "STARTING SQL SCRIPT EXECUTION PROCESS"
    log "INFO" "========================================"
    
    local overall_start_time=$(date +%s)
    local execution_success=true
    
    # Execute scripts in the defined order
    for order_key in $(printf '%s\n' "${!SCRIPT_FOLDERS[@]}" | sort); do
        local folder_name="${SCRIPT_FOLDERS[$order_key]}"
        local folder_path="$SCRIPTS_BASE_PATH/$folder_name"
        
        log "INFO" "Processing folder: $folder_name ($folder_path)"
        
        if [[ -d "$folder_path" ]]; then
            if ! execute_scripts_in_folder "$folder_path"; then
                log "ERROR" "Failed to execute scripts in folder: $folder_name"
                if [[ "$CONTINUE_ON_ERROR" != "true" ]]; then
                    execution_success=false
                    break
                else
                    execution_success=false  # Mark as failed but continue
                    log "WARNING" "Continuing despite failures due to CONTINUE_ON_ERROR setting"
                fi
            fi
        else
            log "WARNING" "Script folder not found, skipping: $folder_path"
            continue
        fi
        
        # Delay between folders
        sleep 2
    done
    
    local overall_end_time=$(date +%s)
    local total_execution_time=$((overall_end_time - overall_start_time))
    
    # Generate comprehensive execution summary
    generate_execution_summary "$total_execution_time" "$execution_success"
    
    return $([ "$execution_success" = true ] && echo 0 || echo 1)
}

generate_execution_summary() {
    local total_time="$1"
    local success="$2"
    
    log "INFO" "========================================"
    log "INFO" "GENERATING EXECUTION SUMMARY REPORT"
    log "INFO" "========================================"
    
    # Calculate success rate
    local success_rate=0
    if [[ ${EXECUTION_STATS["total_scripts"]} -gt 0 ]]; then
        success_rate=$(( EXECUTION_STATS["successful_scripts"] * 100 / EXECUTION_STATS["total_scripts"] ))
    fi
    
    # Create detailed summary report
    cat > "$SUMMARY_LOG_FILE" << EOF
=============================================================================
Enhanced SQL Script Execution Summary Report
=============================================================================
Execution Date: $(date)
Database Server: $DB_SERVER
Database Name: $DB_NAME
Total Execution Time: ${total_time}s ($(date -d@$total_time -u +%H:%M:%S))

EXECUTION STATISTICS:
- Total Scripts Found: ${EXECUTION_STATS["total_scripts"]}
- Successfully Executed: ${EXECUTION_STATS["successful_scripts"]}
- Failed: ${EXECUTION_STATS["failed_scripts"]}
- Excluded: ${EXECUTION_STATS["excluded_scripts"]}
- Skipped: ${EXECUTION_STATS["skipped_scripts"]}
- Retried: ${EXECUTION_STATS["retried_scripts"]}

SUCCESS RATE: ${success_rate}%

FOLDER EXECUTION CONFIGURATION:
$(for order_key in $(printf '%s\n' "${!SCRIPT_FOLDERS[@]}" | sort); do
    folder_name="${SCRIPT_FOLDERS[$order_key]}"
    execution_mode="${FOLDER_EXECUTION_MODES[$folder_name]:-sequential}"
    handling_strategy="${OBJECT_HANDLING[$folder_name]:-create_only}"
    echo "  $order_key: $folder_name"
    echo "    - Description: ${FOLDER_DESCRIPTIONS[$folder_name]:-$folder_name}"
    echo "    - Execution Mode: $execution_mode"
    echo "    - Object Handling: $handling_strategy"
done)

EXCLUSION SUMMARY:
- Excluded File Patterns: ${#EXCLUDED_FILES[@]} patterns configured
- Excluded Folders: ${#EXCLUDED_FOLDERS[@]} folders configured
- Total Excluded Scripts: ${EXECUTION_STATS["excluded_scripts"]}

DETAILED LOGS:
- Main Log: $MAIN_LOG_FILE
- Error Log: $ERROR_LOG_FILE
- Excluded Scripts Log: $EXCLUDED_SCRIPTS_LOG
- Execution Tracker: $EXECUTION_TRACKER

CONFIGURATION SETTINGS:
- Max Parallel Jobs: $MAX_PARALLEL_JOBS
- Retry Attempts: $RETRY_ATTEMPTS
- Continue on Error: $CONTINUE_ON_ERROR
- Force Recreate: $FORCE_RECREATE

OVERALL STATUS: $([ "$success" = true ] && echo "SUCCESS" || echo "FAILED")
=============================================================================
EOF
    
    # Display summary to console
    cat "$SUMMARY_LOG_FILE"
    
    # Show detailed error analysis if there were failures
    if [[ ${EXECUTION_STATS["failed_scripts"]} -gt 0 ]]; then
        log "WARNING" "=== FAILURE ANALYSIS ==="
        log "WARNING" "Failed scripts details:"
        
        grep "^FAILED" "$EXECUTION_TRACKER" 2>/dev/null | while IFS='|' read -r status folder script_name exec_time retry_count error_msg; do
            log "WARNING" "  - [$folder] $script_name: $error_msg"
        done || true
    fi
    
    # Show excluded scripts summary
    if [[ ${EXECUTION_STATS["excluded_scripts"]} -gt 0 ]]; then
        log "INFO" "=== EXCLUSION SUMMARY ==="
        log "INFO" "Excluded ${EXECUTION_STATS["excluded_scripts"]} scripts - see $EXCLUDED_SCRIPTS_LOG for details"
    fi
    
    # Final status logging
    if [[ "$success" == "true" ]]; then
        log "SUCCESS" "SQL script execution completed successfully!"
        log "SUCCESS" "Summary report saved to: $SUMMARY_LOG_FILE"
    else
        log "ERROR" "SQL script execution completed with errors!"
        log "ERROR" "Check error log for details: $ERROR_LOG_FILE"
        log "ERROR" "Check execution tracker for script-level details: $EXECUTION_TRACKER"
    fi
}

# =============================================================================
# DATABASE CONNECTION AND VALIDATION
# =============================================================================

test_database_connection() {
    log "INFO" "Testing database connection..."
    
    local test_query="SELECT @@VERSION as SqlVersion, DB_NAME() as CurrentDatabase"
    local connection_test
    
    if connection_test=$(/opt/mssql-tools/bin/sqlcmd -S "$DB_SERVER" -U sa -P "$SA_PASSWORD" -d "$DB_NAME" \
        -Q "$test_query" -h-1 -W -t "$DB_TIMEOUT" 2>&1); then
        
        log "SUCCESS" "Database connection established successfully"
        # log "DEBUG" "Database info: $connection_test"
        return 0
    else
        log "ERROR" "Failed to connect to database: $connection_test"
        return 1
    fi
}

verify_database_ready() {
    log "INFO" "Verifying database is ready for script execution..."
    
    local ready_check_query="
    SELECT 
        CASE 
            WHEN DATABASEPROPERTYEX('$DB_NAME', 'Status') = 'ONLINE' 
            AND DATABASEPROPERTYEX('$DB_NAME', 'UserAccess') = 'MULTI_USER'
            THEN 'READY'
            ELSE 'NOT_READY'
        END as DatabaseStatus
    "
    
    local db_status
    if db_status=$(/opt/mssql-tools/bin/sqlcmd -S "$DB_SERVER" -U sa -P "$SA_PASSWORD" \
        -Q "$ready_check_query" -h-1 -W -t 30 2>/dev/null); then
        
        if echo "$db_status" | grep -q "READY"; then
            log "SUCCESS" "Database '$DB_NAME' is ready for script execution"
            return 0
        else
            log "ERROR" "Database '$DB_NAME' is not ready: $db_status"
            return 1
        fi
    else
        log "ERROR" "Failed to verify database readiness"
        return 1
    fi
}

# =============================================================================
# CLEANUP AND ERROR HANDLING
# =============================================================================

cleanup() {
    log "INFO" "Performing cleanup operations..."
    
    # Kill any remaining background processes
    for pid in $(jobs -p); do
        kill "$pid" 2>/dev/null || true
    done
    
    # Clean up temporary files
    rm -f /tmp/sql_exec_* 2>/dev/null || true
    
    # Compress logs if successful and they're large
    if [[ -f "$MAIN_LOG_FILE" && $(stat -c%s "$MAIN_LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
        gzip "$MAIN_LOG_FILE" 2>/dev/null || true
    fi
    
    log "INFO" "Cleanup completed"
}

# Set up signal handlers
trap cleanup EXIT
trap 'log "ERROR" "Script interrupted by user"; exit 130' INT TERM

# =============================================================================
# ENHANCED UTILITY FUNCTIONS
# =============================================================================

show_execution_help() {
    cat << EOF
Enhanced SQL Script Execution Engine
===================================

Usage: $SCRIPT_NAME [OPTIONS]

Environment Variables:
  DB_SERVER              Database server (default: localhost)
  DB_NAME                Database name (default: AdminDB)
  SA_PASSWORD            SA password (required)
  SCRIPTS_BASE_PATH      Path to SQL scripts (default: /var/opt/mssql/scripts)
  LOG_BASE_PATH          Path for logs (default: /var/opt/mssql/logs)
  MAX_PARALLEL_JOBS      Max parallel executions (default: 5)
  RETRY_ATTEMPTS         Retry attempts for failed scripts (default: 3)
  CONTINUE_ON_ERROR      Continue on script failures (default: true)
  FORCE_RECREATE         Force recreate objects (default: false)

Folder Structure Expected:
  \$SCRIPTS_BASE_PATH/
  ├── functions/         (executed in parallel)
  ├── tables/            (executed sequentially)
  ├── procedures/        (executed sequentially)
  └── base-data/         (executed in parallel)

Exclusion Configuration:
  - Files matching patterns in EXCLUDED_FILES array are skipped
  - Folders in EXCLUDED_FOLDERS array are completely ignored
  - Current exclusions: ${#EXCLUDED_FILES[@]} file patterns, ${#EXCLUDED_FOLDERS[@]} folder patterns

Examples:
  # Basic execution
  ./execute-sql-scripts.sh
  
  # With custom settings
  DB_NAME=ProductionDB MAX_PARALLEL_JOBS=3 ./execute-sql-scripts.sh
  
  # Force recreation of all objects
  FORCE_RECREATE=true ./execute-sql-scripts.sh

EOF
}

# =============================================================================
# SCRIPT DEPENDENCY ANALYSIS (Advanced Feature)
# =============================================================================

analyze_script_dependencies() {
    local script_file="$1"
    local dependencies=()
    
    # Extract table/function references from script
    while IFS= read -r line; do
        # Look for references to other objects
        if echo "$line" | grep -qiE "(FROM|JOIN|REFERENCES)\s+(\[?dbo\]?\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?"; then
            local referenced_object=$(echo "$line" | sed -nE 's/.*[FROM|JOIN|REFERENCES]\s+(\[?dbo\]?\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?.*/\2/pi')
            if [[ -n "$referenced_object" && "$referenced_object" != "dbo" ]]; then
                dependencies+=("$referenced_object")
            fi
        fi
    done < "$script_file"
    
    # Remove duplicates
    local unique_deps=($(printf '%s\n' "${dependencies[@]}" | sort -u))
    
    if [[ ${#unique_deps[@]} -gt 0 ]]; then
        log "DEBUG" "Dependencies found: $(IFS=,; echo "${unique_deps[*]}")" "$script_file"
    fi
    
    return 0
}

# =============================================================================
# MAIN SCRIPT ENTRY POINT
# =============================================================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_execution_help
                exit 0
                ;;
            --dry-run)
                readonly DRY_RUN=true
                log "INFO" "DRY RUN mode enabled - no scripts will be executed"
                shift
                ;;
            --list-excluded)
                log "INFO" "=== EXCLUSION CONFIGURATION ==="
                log "INFO" "Excluded File Patterns:"
                printf '  - %s\n' "${EXCLUDED_FILES[@]}"
                log "INFO" "Excluded Folders:"
                printf '  - %s\n' "${EXCLUDED_FOLDERS[@]}"
                exit 0
                ;;
            *)
                log "WARNING" "Unknown parameter: $1"
                shift
                ;;
        esac
    done
    
    log "INFO" "Enhanced SQL Script Execution Engine Starting..."
    log "INFO" "Script: $SCRIPT_NAME"
    log "INFO" "Version: Production-Ready v2.0 with Exclusions"
    log "INFO" "Database: $DB_NAME@$DB_SERVER"
    log "INFO" "Exclusions: ${#EXCLUDED_FILES[@]} file patterns, ${#EXCLUDED_FOLDERS[@]} folders"
    
    # Validate required environment
    if [[ -z "$SA_PASSWORD" ]]; then
        log "ERROR" "SA_PASSWORD environment variable is required"
        exit 1
    fi
    
    # Initialize environment
    create_directories
    initialize_execution_tracker
    
    # Validate database connectivity
    if ! test_database_connection; then
        log "ERROR" "Database connection test failed - cannot proceed"
        exit 1
    fi
    
    if ! verify_database_ready; then
        log "ERROR" "Database readiness check failed - cannot proceed"
        exit 1
    fi
    
    # Show configuration summary
    log "INFO" "=== EXECUTION CONFIGURATION ==="
    log "INFO" "Scripts Path: $SCRIPTS_BASE_PATH"
    log "INFO" "Max Parallel Jobs: $MAX_PARALLEL_JOBS"
    log "INFO" "Retry Attempts: $RETRY_ATTEMPTS"
    log "INFO" "Continue on Error: $CONTINUE_ON_ERROR"
    log "INFO" "Force Recreate: $FORCE_RECREATE"
    
    # Execute all scripts
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "INFO" "DRY RUN - Script discovery only"
        
        for order_key in $(printf '%s\n' "${!SCRIPT_FOLDERS[@]}" | sort); do
            local folder_name="${SCRIPT_FOLDERS[$order_key]}"
            local folder_path="$SCRIPTS_BASE_PATH/$folder_name"
            
            if [[ -d "$folder_path" ]]; then
                log "INFO" "Would process folder: $folder_name"
                discover_scripts_in_folder "$folder_path" >/dev/null
            fi
        done
        
        log "INFO" "DRY RUN completed - ${EXECUTION_STATS["total_scripts"]} scripts would be executed"
        log "INFO" "DRY RUN completed - ${EXECUTION_STATS["excluded_scripts"]} scripts would be excluded"
        
    else
        if execute_all_scripts; then
            log "SUCCESS" "All SQL scripts executed successfully!"
            exit 0
        else
            log "ERROR" "SQL script execution completed with errors!"
            
            # Provide actionable next steps
            log "ERROR" "=== RECOMMENDED NEXT STEPS ==="
            log "ERROR" "1. Review error log: $ERROR_LOG_FILE"
            log "ERROR" "2. Check execution tracker: $EXECUTION_TRACKER"
            log "ERROR" "3. Fix failed scripts and re-run with CONTINUE_ON_ERROR=true"
            log "ERROR" "4. Consider adding problematic scripts to exclusion list"
            
            exit 1
        fi
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi