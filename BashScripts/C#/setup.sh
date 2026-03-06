#!/bin/bash
set -e




echo "Setting up multi-repository Docker environment..."


# Linux Prerequisites Installation & Configuration Guide
## Complete Setup for Angular + C# Application Hosting



## 1. System Preparation & Hardening

### 1.1 Initial System Setup

# Update system packages
sudo apt update && sudo apt upgrade -y

# Install essential packages
sudo apt install -y curl wget gnupg2 software-properties-common \
    apt-transport-https ca-certificates lsb-release \
    build-essential unzip zip htop tree vim nano \
    net-tools ufw fail2ban logrotate rsync

# Install monitoring tools
sudo apt install -y htop iotop nethogs iftop sysstat


### 1.2 Security Hardening

# Configure UFW Firewall
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable

# Configure Fail2Ban
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

if [ -f /etc/fail2ban/jail.local ]; then
    sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak
fi
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
	[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Disable root login and configure SSH
sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh


### 1.3 Create Application User
# Variables
USERNAME="appuser"
PASSWORD="#1Cl@zyW0rk$Adm!N^6969"

# Create dedicated system user
sudo adduser --system --group --home /opt/$USERNAME --shell /bin/bash $USERNAME

# Add to sudo group
sudo usermod -aG sudo $USERNAME

# Set password for user
echo "$USERNAME:$PASSWORD" | sudo chpasswd

# Create application directories
sudo mkdir -p /opt/applications/{backend,frontend}
sudo mkdir -p /opt/logs/{application,nginx}
sudo mkdir -p /opt/scripts/{deployment,monitoring}
sudo mkdir -p /opt/ssl/certificates

# Set ownership and permissions
sudo chown -R appuser:appuser /opt/applications
sudo chown -R appuser:appuser /opt/logs
sudo chown -R appuser:appuser /opt/scripts
sudo chmod -R 750 /opt/applications
sudo chmod -R 755 /opt/logs




## 2. .NET 6.0.35 Runtime Installation (Production Optimized)

### 2.1 Microsoft Repository Setup

# 1. Clean up existing Microsoft repository
# sudo rm -f /etc/apt/sources.list.d/microsoft-prod.list
# sudo rm -f /etc/apt/trusted.gpg.d/microsoft.asc

# # 2. Install correct Microsoft repository for Ubuntu 22.04
# wget https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
# sudo dpkg -i packages-microsoft-prod.deb
# rm packages-microsoft-prod.deb

# # 3. Update package cache
# sudo apt update

# # 4. Install .NET 6.0 Runtime
# sudo apt install -y dotnet-runtime-6.0 aspnetcore-runtime-6.0

# 5. Verify installation
# dotnet --version
# dotnet --list-runtimes


# Verify installation and check version
# dotnet --info
# dotnet --list-runtimes

# Ensure we have the correct version (6.0.35)
# echo "Expected version: 6.0.35"
# dotnet --version

# Configure .NET for production
# echo 'export DOTNET_ENVIRONMENT=Production' | sudo tee -a /etc/environment
# echo 'export ASPNETCORE_ENVIRONMENT=Production' | sudo tee -a /etc/environment
# echo 'export DOTNET_PRINT_TELEMETRY_MESSAGE=false' | sudo tee -a /etc/environment
# echo 'export DOTNET_CLI_TELEMETRY_OPTOUT=1' | sudo tee -a /etc/environment


### 2.3 Performance Optimization

# # Configure garbage collection for server
# echo 'export DOTNET_gcServer=1' | sudo tee -a /etc/environment
# echo 'export DOTNET_gcConcurrent=1' | sudo tee -a /etc/environment

# # Reload environment variables
# source /etc/environment




## 3. Nginx Installation & Optimization

### 3.1 Install Nginx with Additional Modules

# Install Nginx with extras
sudo apt install -y nginx nginx-extras

# Start and enable Nginx
sudo systemctl start nginx
sudo systemctl enable nginx

# Verify installation
nginx -v
sudo systemctl status nginx


### 3.2 Nginx Performance Configuration

# Backup original configuration
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup

# Create optimized nginx.conf
sudo tee /etc/nginx/nginx.conf > /dev/null <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
    accept_mutex off;
}

http {
    # Basic Settings
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    keepalive_requests 1000;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 64M;
    
    # Buffer Settings
    client_body_buffer_size 128k;
    client_header_buffer_size 3m;
    large_client_header_buffers 4 256k;
    output_buffers 1 32k;
    postpone_output 1460;
    
    # Timeouts
    client_header_timeout 3m;
    client_body_timeout 3m;
    send_timeout 3m;
    
    # MIME Types
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    
    # Logging Format
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" "$http_x_forwarded_for" '
                   'rt=$request_time uct="$upstream_connect_time" '
                   'uht="$upstream_header_time" urt="$upstream_response_time"';
    
    # Access Logs
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;
    
    # Gzip Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/json
        application/javascript
        application/xml+rss
        application/atom+xml
        image/svg+xml;
    
    # Brotli Compression (if available)
    #brotli on;
    #brotli_comp_level 6;
    #brotli_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
    # Rate Limiting
    limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=login:10m rate=1r/s;
    
    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    
    # Include server configurations
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
EOF

# Test configuration
sudo nginx -t


### 3.3 Create Directory Structure

# Create custom configuration directories
sudo mkdir -p /etc/nginx/conf.d
sudo mkdir -p /etc/nginx/sites-available
sudo mkdir -p /etc/nginx/sites-enabled
sudo mkdir -p /etc/nginx/snippets

# Remove default site
sudo rm -f /etc/nginx/sites-enabled/default




## 4. SSL Certificate Management

### 4.1 Install Certbot for Let's Encrypt

# Install Certbot
sudo apt install -y certbot python3-certbot-nginx

# Create SSL directory structure
sudo mkdir -p /etc/ssl/private
sudo mkdir -p /etc/ssl/certs
sudo chmod 700 /etc/ssl/private


### 4.2 Generate Strong DH Parameters

# Generate DH parameters (this takes time)
sudo openssl dhparam -out /etc/ssl/certs/dhparam.pem 2048

# Set appropriate permissions
sudo chmod 644 /etc/ssl/certs/dhparam.pem


### 4.3 Create SSL Snippet Configuration

# Create SSL configuration snippet
sudo tee /etc/nginx/snippets/ssl-params.conf > /dev/null <<'EOF'
# SSL Configuration
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-SHA256:ECDHE-RSA-AES256-SHA384;
ssl_prefer_server_ciphers on;
ssl_dhparam /etc/ssl/certs/dhparam.pem;

# SSL Session Settings
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

# OCSP Stapling
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;

# Security Headers
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options "DENY" always;
add_header X-Content-Type-Options "nosniff" always;
add_header X-XSS-Protection "1; mode=block" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
EOF




## 5. System Monitoring & Logging

### 5.1 Configure Log Rotation

# Configure logrotate for application logs
sudo tee /etc/logrotate.d/application > /dev/null <<'EOF'
/opt/logs/application/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0644 appuser appuser
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
EOF

# Configure logrotate for Nginx
sudo tee /etc/logrotate.d/nginx > /dev/null <<'EOF'
/var/log/nginx/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0644 www-data adm
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \
            run-parts /etc/logrotate.d/httpd-prerotate; \
        fi
    endscript
    postrotate
        invoke-rc.d nginx rotate >/dev/null 2>&1
    endscript
}
EOF


### 5.2 Install System Monitoring Tools

# Install monitoring packages
sudo apt install -y prometheus-node-exporter
sudo systemctl enable prometheus-node-exporter
sudo systemctl start prometheus-node-exporter

# Install process monitoring
sudo apt install -y supervisor
sudo systemctl enable supervisor
sudo systemctl start supervisor


### 5.3 Configure System Limits

# Configure system limits for high performance
sudo tee -a /etc/security/limits.conf > /dev/null <<'EOF'
# Application user limits
appuser soft nofile 65536
appuser hard nofile 65536
appuser soft nproc 32768
appuser hard nproc 32768

# Nginx limits
www-data soft nofile 65536
www-data hard nofile 65536
EOF

# Configure systemd limits
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/limits.conf > /dev/null <<'EOF'
[Manager]
DefaultLimitNOFILE=65536
DefaultLimitNPROC=32768
EOF




## 6. Network & Performance Optimization

### 6.1 Kernel Network Optimization

# Optimize kernel network parameters
sudo tee -a /etc/sysctl.conf > /dev/null <<'EOF'
# Network Performance Tuning
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 65536 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# File System
fs.file-max = 2097152
fs.nr_open = 1048576

# Virtual Memory
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
EOF

# Apply changes
sudo sysctl -p


### 6.2 Configure Time Synchronization

# Install and configure NTP
sudo apt install -y chrony
sudo systemctl enable chrony
sudo systemctl start chrony

# Verify time sync
which chronyc




## 7. Security & Compliance

### 7.1 Install and Configure ClamAV

# Install antivirus
if ! command -v clamscan >/dev/null 2>&1; then
    echo "ClamAV not found. Installing..."
    sudo apt update
    sudo apt install -y clamav clamav-daemon

    echo "Enabling and starting clamav-freshclam service..."
    sudo systemctl enable clamav-freshclam
    sudo systemctl start clamav-freshclam

    echo "Updating virus definitions..."
    sudo freshclam || echo "Skipping freshclam manual run, likely already running as daemon"
else
    echo "ClamAV is already installed. Skipping installation."
fi



### 7.2 Configure Audit Logging

# Install auditd
# Install auditd only if not present
if ! dpkg -s auditd >/dev/null 2>&1; then
    echo "Installing auditd and plugins..."
    sudo apt update
    sudo apt install -y auditd audispd-plugins
else
    echo "auditd already installed. Skipping installation."
fi

# Append custom audit rules only if they don't already exist
AUDIT_RULES_FILE="/etc/audit/rules.d/audit.rules"

add_rule_if_missing() {
    local rule="$1"
    grep -F -- "$rule" "$AUDIT_RULES_FILE" >/dev/null 2>&1 || echo "$rule" | sudo tee -a "$AUDIT_RULES_FILE" > /dev/null
}

echo "Adding custom audit rules if missing..."
add_rule_if_missing "-w /opt/applications/ -p wa -k application_files"
add_rule_if_missing "-w /etc/nginx/ -p wa -k nginx_config"
add_rule_if_missing "-w /etc/ssl/ -p wa -k ssl_config"
add_rule_if_missing "-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change"
add_rule_if_missing "-a always,exit -F arch=b32 -S adjtimex -S settimeofday -S stime -k time-change"

# Enable and start auditd
echo "Enabling and starting auditd..."
sudo systemctl enable auditd
sudo systemctl start auditd





## 8. Backup & Recovery Setup

### 8.1 Create Backup Directories

# Create backup structure
sudo mkdir -p /opt/backups/{daily,weekly,monthly}
sudo mkdir -p /opt/backups/scripts

# Set permissions
sudo chown -R appuser:appuser /opt/backups
sudo chmod -R 755 /opt/backups


### 8.2 Install Backup Tools

# Install backup utilities
sudo apt install -y rsync duplicity borgbackup

# Install cloud storage tools (optional)
sudo apt install -y rclone




## 9. Health Check & Monitoring Scripts

### 9.1 Create System Health Check Script

sudo tee /opt/scripts/monitoring/health-check.sh > /dev/null <<'EOF'
#!/bin/bash

# System Health Check Script
LOG_FILE="/opt/logs/health-check.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "[$DATE] Starting health check..." >> $LOG_FILE

# Check system resources
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
MEMORY_USAGE=$(free | grep Mem | awk '{printf("%.2f", $3/$2 * 100.0)}')
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

echo "[$DATE] CPU: ${CPU_USAGE}%, Memory: ${MEMORY_USAGE}%, Disk: ${DISK_USAGE}%" >> $LOG_FILE

# Check services
services=("nginx" "csharp-app")
for service in "${services[@]}"; do
    if systemctl is-active --quiet $service; then
        echo "[$DATE] $service: RUNNING" >> $LOG_FILE
    else
        echo "[$DATE] $service: FAILED" >> $LOG_FILE
    fi
done

# Check ports
ports=("80" "443" "5000")
for port in "${ports[@]}"; do
    if netstat -tuln | grep ":$port " > /dev/null; then
        echo "[$DATE] Port $port: OPEN" >> $LOG_FILE
    else
        echo "[$DATE] Port $port: CLOSED" >> $LOG_FILE
    fi
done

echo "[$DATE] Health check completed." >> $LOG_FILE

EOF

chmod +x /opt/scripts/monitoring/health-check.sh


### 9.2 Setup Cron Jobs

# Add cron jobs for monitoring
# Define the cron jobs
CRON_HEALTH='*/5 * * * * /opt/scripts/monitoring/health-check.sh'
CRON_CERTBOT='0 2 * * * /usr/bin/certbot renew --quiet'

# Temp file to store current cron jobs
TMP_CRON=$(mktemp)

# Save current crontab to temp file (if any)
crontab -l 2>/dev/null > "$TMP_CRON" || true

# Add health-check cronjob if not already present
grep -F -- "$CRON_HEALTH" "$TMP_CRON" >/dev/null || echo "$CRON_HEALTH" >> "$TMP_CRON"

# Add certbot cronjob if not already present
grep -F -- "$CRON_CERTBOT" "$TMP_CRON" >/dev/null || echo "$CRON_CERTBOT" >> "$TMP_CRON"




echo "=== Service Status Check ==="
services=("nginx" "ufw" "fail2ban" "chrony" "auditd" "prometheus-node-exporter")

for service in "${services[@]}"; do
    if systemctl is-active --quiet $service; then
        echo "✓ $service: RUNNING"
    else
        echo "✗ $service: FAILED"
    fi
done


### 10.2 Network Configuration Check

# Verify network configuration
echo "=== Network Configuration ==="
echo "Firewall Status:"
sudo ufw status

echo "Open Ports:"
sudo netstat -tuln | grep LISTEN

echo "SSL Configuration:"
openssl version -a


### 10.3 System Performance Baseline

# Create performance baseline
echo "=== System Performance Baseline ==="
echo "CPU Info:"
lscpu | grep -E '^Thread|^Core|^Socket|^CPU'

echo "Memory Info:"
free -h

echo "Disk Info:"
df -h

echo "Network Interfaces:"
ip addr show




# ## 11. Post-Installation Checklist


# ## 12. Next Steps

# After completing this prerequisites setup:

# 1. **Proceed to application migration document**
# 2. **Configure domain DNS records**
# 3. **Obtain and install SSL certificates**
# 4. **Deploy applications using DevOps pipeline**
# 5. **Set up monitoring and alerting**
# 6. **Configure backup schedules**
# 7. **Perform security audit**



#**System is now ready for application deployment with production-grade security, performance, and monitoring capabilities.**




# Install Docker dependencies
sudo apt update
sudo apt install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

# Add Docker's official GPG key
sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker Engine
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add user to docker group
sudo usermod -aG docker $USER
id -u devops &>/dev/null || sudo adduser devops

sudo usermod -aG docker devops

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Test Docker installation
sudo docker run hello-world



# # Install Java (required for Jenkins)
# sudo apt install -y openjdk-17-jdk

# # Add Jenkins repository
# curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
#   /usr/share/keyrings/jenkins-keyring.asc > /dev/null

# echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
#   https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
#   /etc/apt/sources.list.d/jenkins.list > /dev/null

# # Install Jenkins
# sudo apt update
# sudo apt install -y jenkins

# # Start and enable Jenkins
# sudo systemctl start jenkins
# sudo systemctl enable jenkins

# # Add Jenkins user to docker group
# sudo usermod -aG docker jenkins
# sudo systemctl restart jenkins

# # Check Jenkins status
# sudo systemctl status jenkins



# # Get Jenkins initial admin password
# sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# # Note: Save this password - you'll need it for the web setup


# Test Docker
docker run --rm hello-world

# Test Docker Compose
docker compose version


# Test Nginx (should be running on port 80)
curl -I http://localhost

# Check all services
sudo systemctl is-active docker  nginx fail2ban



# Configure SSH (optional but recommended)
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config



# Restart SSH service
sudo systemctl restart ssh

# Set up log rotation
sudo tee /etc/logrotate.d/docker > /dev/null <<'EOF'
	/var/lib/docker/containers/*/*.log {
    rotate 7
    daily
    compress
    size=10M
    missingok
    delaycompress
    copytruncate
}

EOF




# System info
echo "=== System Information ==="
lsb_release -a
uname -a

echo "=== Docker Status ==="
docker --version
docker info

# echo "=== Jenkins Status ==="
# sudo systemctl status jenkins --no-pager

echo "=== Nginx Status ==="
sudo systemctl status nginx --no-pager

echo "=== Firewall Status ==="
sudo ufw status

echo "=== Fail2Ban Status ==="
sudo systemctl status fail2ban --no-pager

echo "=== Disk Usage ==="
df -h

echo "=== Memory Usage ==="
free -h

echo "=== Network Ports ==="
sudo netstat -tlnp | grep -E ':80|:443|:8080|:22'








# Add appuser to necessary groups
sudo usermod -aG docker appuser
sudo usermod -aG sudo appuser




# # Install Node.js (Jenkins needs this to build Angular)
# cd /tmp
# wget https://nodejs.org/dist/v16.14.0/node-v16.14.0-linux-x64.tar.xz
# tar -xf node-v16.14.0-linux-x64.tar.xz
# sudo mv node-v16.14.0-linux-x64 /usr/local/lib/nodejs

# # Add to PATH (for current session)
# export PATH=/usr/local/lib/nodejs/bin:$PATH

# # Add to shell profile for future sessions
# echo 'export PATH=/usr/local/lib/nodejs/bin:$PATH' >> ~/.bashrc
# source ~/.bashrc


# # Install .NET SDK (Jenkins needs this to build C# API)
# wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
# sudo dpkg -i packages-microsoft-prod.deb
# sudo rm -f packages-microsoft-prod.deb

# sudo apt update
# sudo apt install -y dotnet-sdk-8.0


# # Verify installations
# node --version
# npm --version
# dotnet --version

# # set -e  # Exit immediately if a command exits with a non-zero status

# Configurable variables
REDIS_PASSWORD="Red!$Adm!N^69"
MAX_MEMORY="256mb"
REDIS_CONF="/etc/redis/redis.conf"

echo "[1/6] Installing Redis..."
sudo apt update
sudo apt install -y redis-server

echo "[2/6] Enabling Redis service to start on boot..."
sudo systemctl enable redis-server
sudo systemctl start redis-server

echo "[3/6] Configuring Redis security and performance..."

# Backup original config
sudo cp $REDIS_CONF ${REDIS_CONF}.bak.$(date +%F_%T)

# Secure Redis: only allow localhost access
sudo sed -i "s/^bind .*/bind 127.0.0.1/" $REDIS_CONF

# Set requirepass if not already set
if grep -q "^# requirepass" $REDIS_CONF; then
    sudo sed -i "s/^# requirepass .*/requirepass $REDIS_PASSWORD/" $REDIS_CONF
elif grep -q "^requirepass" $REDIS_CONF; then
    sudo sed -i "s/^requirepass .*/requirepass $REDIS_PASSWORD/" $REDIS_CONF
else
    echo "requirepass $REDIS_PASSWORD" | sudo tee -a $REDIS_CONF > /dev/null
fi

# Set maxmemory and eviction policy
sudo sed -i "s/^# maxmemory <bytes>/maxmemory $MAX_MEMORY/" $REDIS_CONF || true
sudo sed -i "s/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/" $REDIS_CONF || true

# If not already present, append it
grep -q "^maxmemory " $REDIS_CONF || echo "maxmemory $MAX_MEMORY" | sudo tee -a $REDIS_CONF > /dev/null
grep -q "^maxmemory-policy " $REDIS_CONF || echo "maxmemory-policy allkeys-lru" | sudo tee -a $REDIS_CONF > /dev/null

echo "[4/6] Restarting Redis..."
sudo systemctl restart redis

echo "[5/6] Testing Redis Authentication..."
REDIS_AUTH_OUTPUT=$(redis-cli -a "$REDIS_PASSWORD" PING)

if [[ "$REDIS_AUTH_OUTPUT" == "PONG" ]]; then
    echo "[6/6] Redis setup complete and authenticated successfully!"
else
    echo "❌ Redis authentication failed. Check password or configuration."
    exit 1
fi




# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
newgrp docker

# Install Docker Compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Install additional tools
sudo apt install -y jq curl git

sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "7"
  }
}
EOF
sudo systemctl restart docker


# Create volume directories
echo "Creating host volume directories..."
sudo mkdir -p /opt/mssql/{data,logs,backup}
sudo mkdir -p /opt/redis/data
sudo mkdir -p /opt/grafana/data
sudo mkdir -p /opt/prometheus/data
mkdir -p nginx/{ssl,logs}

# Set permissions
echo "Setting permissions..."
sudo chown -R 10001:0 /opt/mssql/
sudo chown -R 999:999 /opt/redis/
sudo chown -R 472:472 /opt/grafana/
sudo chown -R 65534:65534 /opt/prometheus/
sudo chmod -R 755 /opt/{mssql,redis,grafana,prometheus}

# Generate SSL certificates
echo "Generating SSL certificates..."
if [ ! -f nginx/ssl/cert.pem ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout nginx/ssl/key.pem \
      -out nginx/ssl/cert.pem \
      -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost"
fi

# Create Redis configuration
echo "Creating Redis configuration..."
cat > volumes/redis/conf/redis.conf << 'EOF'
bind 0.0.0.0
port 6379
timeout 300
tcp-keepalive 60
maxmemory 512mb
maxmemory-policy allkeys-lru
appendonly yes
appendfsync everysec
save 900 1
save 300 10
save 60 10000
EOF

echo "Setup completed successfully!"

