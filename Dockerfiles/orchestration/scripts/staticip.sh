#!/bin/bash
set -e

# Static IP configuration
INTERFACE_NAME="enp0s3"  # You can change this if needed
STATIC_IP="192.168.0.100/24"
GATEWAY="192.168.0.1"
DNS_SERVERS="8.8.8.8,8.8.4.4"

echo "Configuring static IP for interface: $INTERFACE_NAME"

# Disable cloud-init network overwrite (if needed)
sudo mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Backup existing Netplan config
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
sudo cp /etc/netplan/*.yaml "/etc/netplan/backup-$TIMESTAMP.yaml"

# Write static Netplan config
sudo tee /etc/netplan/01-static-ip.yaml > /dev/null <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE_NAME}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}
      routes:
        - to: 0.0.0.0/0
          via: ${GATEWAY}
      nameservers:
        addresses: [${DNS_SERVERS}]
EOF

# Apply Netplan changes
echo "Applying Netplan changes..."
sudo netplan apply

echo "✅ Static IP $STATIC_IP applied to interface $INTERFACE_NAME"
echo "Gateway set to $GATEWAY"
echo "DNS servers set to $DNS_SERVERS"