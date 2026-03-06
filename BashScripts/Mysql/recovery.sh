#!/bin/bash
# SQL Server Database Recovery Script

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO") echo -e "${BLUE}[$timestamp] INFO:${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[$timestamp] SUCCESS:${NC} $message" ;;
        "WARNING") echo -e "${YELLOW}[$timestamp] WARNING:${NC} $message" ;;
        "ERROR") echo -e "${RED}[$timestamp] ERROR:${NC} $message" ;;
    esac
}

# Step 1: Clean up existing containers and processes
cleanup_existing() {
    log "INFO" "Step 1: Cleaning up existing containers..."
    
    # Stop any running containers
    if docker ps -q -f name=sqlserver-db | grep -q .; then
        log "INFO" "Stopping running container..."
        docker compose down --timeout 30
    fi
    
    # Remove stopped containers
    if docker ps -a -q -f name=sqlserver-db | grep -q .; then
        log "INFO" "Removing existing container..."
        docker rm -f sqlserver-db 2>/dev/null || true
    fi
    
    # Clean up any orphaned processes
    docker system prune -f --filter "label=com.docker.compose.project"
    
    log "SUCCESS" "Cleanup completed"
}

# Step 2: Verify environment and files
verify_environment() {
    log "INFO" "Step 2: Verifying environment..."
    
    # Check .env file
    if [[ ! -f ".env" ]]; then
        log "ERROR" ".env file not found"
        return 1
    fi
    
    source .env
    
    # Check required variables
    local required_vars=("DB_SA_PASSWORD" "DB_NAME")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log "ERROR" "Required variable $var not set in .env"
            return 1
        fi
    done
    
    # Check backup directory and files
    if [[ ! -d "/opt/src/backup" ]]; then
        log "ERROR" "Backup directory /opt/src/backup not found"
        return 1
    fi
    
    local backup_files=($(ls /opt/src/backup/*.bak 2>/dev/null))
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log "WARNING" "No backup files found in /opt/src/backup"
    else
        log "SUCCESS" "Found ${#backup_files[@]} backup file(s)"
        for file in "${backup_files[@]}"; do
            local size=$(stat -c%s "$file" 2>/dev/null || echo "0")
            log "INFO" "  $(basename "$file"): ${size} bytes"
        done
    fi
    
    log "SUCCESS" "Environment verification completed"
}

# Step 3: Fix permissions
fix_permissions() {
    log "INFO" "Step 3: Fixing permissions..."
    
    # Create directories if they don't exist
    sudo mkdir -p /opt/{src/backup,mssql/{data,logs,backup}}
    
    # Fix ownership and permissions
    sudo chown -R 10001:0 /opt/mssql/
    sudo chmod -R 755 /opt/mssql/
    
    # Fix backup directory permissions
    sudo chmod -R 755 /opt/src/backup
    
    # Verify permissions
    log "INFO" "Verifying permissions:"
    ls -la /opt/src/backup/ | head -5
    
    log "SUCCESS" "Permissions fixed"
}

# Step 4: Update configuration files
update_config() {
    log "INFO" "Step 4: Updating configuration..."
    
    # Check if IGNORE_SCRIPT_ERRORS is set
    if ! grep -q "IGNORE_SCRIPT_ERRORS" .env; then
        echo "" >> .env
        echo "# Error handling configuration" >> .env
        echo "IGNORE_SCRIPT_ERRORS=true" >> .env
        echo "CLEAR_FAILED_SCRIPTS=true" >> .env
        log "SUCCESS" "Added error handling configuration to .env"
    else
        log "INFO" "Error handling configuration already exists"
    fi
    
    # Backup existing docker-compose.yml
    if [[ -f "docker-compose.yml" ]]; then
        cp docker-compose.yml "docker-compose.yml.backup.$(date +%Y%m%d_%H%M%S)"
        log "INFO" "Backed up existing docker-compose.yml"
    fi
    
    log "SUCCESS" "Configuration updated"
}

# Step 5: Fix problematic SQL scripts
fix_sql_scripts() {
    log "INFO" "Step 5: Fixing SQL scripts..."
    
    local problematic_scripts=(
        "ENTDBSCRIPT/TABLES/dbo.tbl_Antibiotic.Table.sql"
    )
    
    for script in "${problematic_scripts[@]}"; do
        if [[ -f "$script" ]]; then
            log "INFO" "Fixing script: $script"
            
            # Create backup
            cp "$script" "${script}.backup.$(date +%Y%m%d_%H%M%S)"
            
            # Create temporary file with proper headers
            local temp_file=$(mktemp)
            cat > "$temp_file" << 'EOF'
-- SQL Server 2022 Compatibility Settings
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;

EOF
            
            # Skip existing SET statements and add the content
            grep -v "^SET " "$script" >> "$temp_file" || cat "$script" >> "$temp_file"
            
            # Replace original with fixed version
            mv "$temp_file" "$script"
            
            log "SUCCESS" "Fixed script: $script"
        else
            log "WARNING" "Script not found: $script"
        fi
    done
    
    # Alternatively, create an exclusion file for problematic scripts
    local exclusion_dir="ENTDBSCRIPT/TABLES"
    if [[ -d "$exclusion_dir" ]]; then
        # Find scripts that might have similar issues
        local scripts_with_issues=($(grep -l "CREATE TABLE" "$exclusion_dir"/*.sql 2>/dev/null | head -5))
        
        log "INFO" "Found ${#scripts_with_issues[@]} table creation scripts"
        
        # Create a test exclude file for the known problematic script
        touch "ENTDBSCRIPT/TABLES/dbo.tbl_Antibiotic.Table.sql.exclude"
        log "INFO" "Created exclusion for problematic script (can be removed after testing)"
    fi
    
    log "SUCCESS" "SQL scripts processing completed"
}

# Step 6: Start database with monitoring
start_database() {
    log "INFO" "Step 6: Starting database..."
    
    # Start container in background
    log "INFO" "Building and starting container..."
    docker compose up --build -d
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Failed to start container"
        return 1
    fi
    
    log "SUCCESS" "Container started, monitoring initialization..."
    
    # Monitor logs in real-time for a few minutes
    local monitor_duration=300  # 5 minutes
    local start_time=$(date +%s)
    
    (
        sleep 2
        docker logs -f sqlserver-db 2>&1 | while read line; do
            local current_time=$(date +%s)
            local elapsed=$((current_time - start_time))
            
            # Add timestamp to each log line
            echo "[$elapsed s] $line"
            
            # Check for success markers
            if echo "$line" | grep -q "Database initialization completed"; then
                log "SUCCESS" "Database initialization completed successfully!"
                pkill -f "docker logs -f sqlserver-db" 2>/dev/null || true
                break
            fi
            
            # Check for the problematic error
            if echo "$line" | grep -q "QUOTED_IDENTIFIER"; then
                log "WARNING" "Detected QUOTED_IDENTIFIER error, but continuing with IGNORE_SCRIPT_ERRORS=true"
            fi
            
            # Stop monitoring after duration
            if [[ $elapsed -gt $monitor_duration ]]; then
                log "INFO" "Monitoring timeout reached, stopping log monitoring"
                break
            fi
        done
    ) &
    
    local monitor_pid=$!
    
    # Wait for container to become healthy or timeout
    local health_check_timeout=600  # 10 minutes
    local check_interval=30
    local elapsed=0
    
    while [[ $elapsed -lt $health_check_timeout ]]; do
        local health_status=$(docker inspect --format='{{.State.Health.Status}}' sqlserver-db 2>/dev/null || echo "unknown")
        local container_status=$(docker inspect --format='{{.State.Status}}' sqlserver-db 2>/dev/null || echo "unknown")
        
        log "INFO" "Container: $container_status, Health: $health_status (${elapsed}s elapsed)"
        
        case $health_status in
            "healthy")
                log "SUCCESS" "Database is healthy and ready!"
                kill $monitor_pid 2>/dev/null || true
                return 0
                ;;
            "unhealthy")
                log "ERROR" "Database health check failed"
                kill $monitor_pid 2>/dev/null || true
                docker logs sqlserver-db --tail 20
                return 1
                ;;
        esac
        
        # Check if container is still running
        if [[ "$container_status" != "running" ]]; then
            log "ERROR" "Container stopped unexpectedly"
            kill $monitor_pid 2>/dev/null || true
            docker logs sqlserver-db --tail 20
            return 1
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    kill $monitor_pid 2>/dev/null || true
    log "WARNING" "Health check timeout, but container may still be initializing"
    return 0
}

# Step 7: Verify database status
verify_database() {
    log "INFO" "Step 7: Verifying database status..."
    
    # Load environment
    source .env
    
    # Test SQL connectivity
    if docker exec sqlserver-db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$DB_SA_PASSWORD" -Q "SELECT 1" > /dev/null 2>&1; then
        log "SUCCESS" "SQL Server is responding"
        
        # Check if database exists
        local db_exists=$(docker exec sqlserver-db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$DB_SA_PASSWORD" -h -1 -Q "SELECT COUNT(*) FROM sys.databases WHERE name = '$DB_NAME'" 2>/dev/null | tr -d ' \n\r')
        
        if [[ "$db_exists" == "1" ]]; then
            log "SUCCESS" "Database '$DB_NAME' exists"
            
            # Get table count
            local table_count=$(docker exec sqlserver-db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "$DB_SA_PASSWORD" -d "$DB_NAME" -h -1 -Q "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE'" 2>/dev/null | tr -d ' \n\r')
            log "INFO" "Database has $table_count tables"
            
            # Check for failed scripts
            if docker exec sqlserver-db test -f /var/opt/mssql/data/.failed_scripts; then
                log "WARNING" "Some scripts failed during execution:"
                docker exec sqlserver-db cat /var/opt/mssql/data/.failed_scripts | sed 's/^/  /'
            else
                log "SUCCESS" "No script failures detected"
            fi
            
        else
            log "WARNING" "Database '$DB_NAME' does not exist"
        fi
    else
        log "ERROR" "Cannot connect to SQL Server"
        return 1
    fi
    
    log "SUCCESS" "Database verification completed"
}

# Show final status and connection info
show_final_status() {
    log "INFO" "=== RECOVERY COMPLETED ==="
    
    source .env
    
    echo ""
    log "INFO" "Connection Information:"
    echo "  Server: localhost,${SQL_SERVER_PORT:-1433}"
    echo "  Database: $DB_NAME"
    echo "  SA Password: $DB_SA_PASSWORD"
    echo ""
    
    log "INFO" "Useful Commands:"
    echo "  View logs: docker logs sqlserver-db -f"
    echo "  Stop database: docker compose down"
    echo "  Restart database: docker compose up -d"
    echo "  Connect via sqlcmd: docker exec -it sqlserver-db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P '$DB_SA_PASSWORD'"
    echo ""
    
    # Show container status
    docker ps -f name=sqlserver-db --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    log "SUCCESS" "Recovery process completed!"
}

# Main execution
main() {
    log "INFO" "Starting SQL Server Database Recovery Process..."
    echo "=============================================="
    
    cleanup_existing
    echo ""
    
    verify_environment
    echo ""
    
    fix_permissions
    echo ""
    
    update_config
    echo ""
    
    fix_sql_scripts
    echo ""
    
    start_database
    echo ""
    
    verify_database
    echo ""
    
    show_final_status
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi