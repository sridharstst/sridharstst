#!/bin/bash

# SQL Server Docker Setup Script
# This script sets up the environment and starts the SQL Server container

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

# Function to create required directories
create_directories() {
    log "INFO" "Creating required directories..."
    
    local directories=(
        "/opt/mssql/data"
        "/opt/mssql/logs" 
        "/opt/mssql/backup"
        "./backup"
        "./scripts/migrations"
    )
    
    for dir in "${directories[@]}"; do
        if [ ! -d "$dir" ]; then
            sudo mkdir -p "$dir"
            log "SUCCESS" "Created directory: $dir"
        else
            log "INFO" "Directory already exists: $dir"
        fi
    done
    
    # Set proper permissions for SQL Server directories
    sudo chown -R 10001:0 /opt/mssql/
    sudo chmod -R 755 /opt/mssql/
}

# Function to validate environment file
validate_env() {
    if [ ! -f ".env" ]; then
        log "ERROR" ".env file not found. Please create it using the template."
        log "INFO" "Copy .env.template to .env and configure your settings."
        exit 1
    fi
    
    # Check for required variables
    source .env
    local required_vars=("DB_SA_PASSWORD" "DB_NAME")
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log "ERROR" "Required environment variable $var is not set in .env file"
            exit 1
        fi
    done
    
    log "SUCCESS" "Environment file validation passed"
}

# Function to check if backup file exists and move it
setup_backup() {
    local backup_file="../backup/${DB_NAME}.bak"
    
    if [ -f "$backup_file" ]; then
        log "INFO" "Found backup file: $backup_file"
        log "INFO" "Database will be restored from backup on first run"
    else
        log "WARNING" "No backup file found at $backup_file"
        log "INFO" "New database will be created from scripts"
    fi
}

# Function to validate SQL scripts
validate_scripts() {
    log "INFO" "Validating SQL script directories..."
    
    local script_dirs=("ENTDBSCRIPT/TABLES" "ENTDBSCRIPT/FUNCTIONS" "ENTDBSCRIPT/PROCEDURES" "ENTDBSCRIPT/BASEDATA")
    
    for dir in "${script_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log "WARNING" "Script directory not found: $dir"
        else
            local script_count=$(find "$dir" -name "*.sql" | wc -l)
            log "INFO" "Found $script_count SQL scripts in $dir"
        fi
    done
}

# Function to create exclude files for scripts that should be skipped
create_exclude_example() {
    log "INFO" "Example: To exclude a script from execution, create a .exclude file"
    log "INFO" "  touch ENTDBSCRIPT/TABLES/problematic_script.sql.exclude"
}

# Function to start the database
start_database() {
    log "INFO" "Starting SQL Server container..."
    
    # Stop existing container if running
    if docker ps -q -f name=sqlserver-db | grep -q .; then
        log "WARNING" "Stopping existing container..."
        docker compose down
    fi
    
    # Build and start the container
    docker compose up  -d
    
    if [ $? -eq 0 ]; then
        log "SUCCESS" "SQL Server container started successfully"
        log "INFO" "Container name: sqlserver-db"
        log "INFO" "Port: ${SQL_SERVER_PORT:-1433}"
    else
        log "ERROR" "Failed to start SQL Server container"
        exit 1
    fi
}

# Function to monitor container startup
# monitor_startup() {
#     log "INFO" "Monitoring container startup..."
    
#     local max_attempts=30
#     local attempt=1
    
#     while [ $attempt -le $max_attempts ]; do
#         local health_status=$(docker inspect --format='{{.State.Health.Status}}' sqlserver-db 2>/dev/null || echo "unknown")
        
#         case $health_status in
#             "healthy")
#                 log "SUCCESS" "Database is healthy and ready!"
#                 break
#                 ;;
#             "unhealthy")
#                 log "ERROR" "Database health check failed"
#                 docker logs sqlserver-db --tail 20
#                 exit 1
#                 ;;
#             "starting")
#                 log "INFO" "Database is starting... ($attempt/$max_attempts)"
#                 ;;
#             *)
#                 log "INFO" "Waiting for container to be ready... ($attempt/$max_attempts)"
#                 ;;
#         esac
        
#         sleep 10
#         ((attempt++))
#     done
    
#     if [ $attempt -gt $max_attempts ]; then
#         log "ERROR" "Database failed to become healthy within timeout"
#         docker logs sqlserver-db --tail 50
#         exit 1
#     fi
# }

# Function to display connection information
show_connection_info() {
    source .env
    
    log "SUCCESS" "Database setup completed successfully!"
    echo ""
    log "INFO" "Connection Information:"
    echo "  Server: localhost,${SQL_SERVER_PORT:-1433}"
    echo "  Database: $DB_NAME"
    echo ""
    log "INFO" "Available Users:"
    echo "  SA (System Admin): sa / $DB_SA_PASSWORD"
    echo "  Read Only User: ${DB_READ_USER:-db_reader} / $DB_READ_PASSWORD"
    echo "  Execute User: ${DB_EXECUTE_USER:-db_executor} / $DB_EXECUTE_PASSWORD" 
    echo "  Application User: ${DB_APP_USER:-db_application} / $DB_APP_PASSWORD"
    echo ""
    log "INFO" "Management Commands:"
    echo "  View logs: docker logs sqlserver-db -f"
    echo "  Stop database: docker-compose down"
    echo "  Start database: docker-compose up -d"
    echo "  Connect via sqlcmd: docker exec -it sqlserver-db /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P '$DB_SA_PASSWORD'"
}

# Main execution
main() {
    log "INFO" "Starting SQL Server Docker setup..."
    
    # Check if Docker is running
    if ! docker info > /dev/null 2>&1; then
        log "ERROR" "Docker is not running. Please start Docker first."
        exit 1
    fi
    
    # Check if docker-compose is available
    if ! docker compose version > /dev/null 2>&1; then
        log "ERROR" "'docker compose' is not available. Please install Docker Compose plugin."
        exit 1
    fi
    validate_env
    create_directories
    setup_backup
    validate_scripts
    create_exclude_example
    start_database
    #monitor_startup
    #show_connection_info
    
    log "SUCCESS" "Setup completed! Database is ready for use."
}

# Run main function
main "$@"