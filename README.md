# n8n Server Setup


NOTE (12-29-2024) THIS IS A ROUGH DRAFT!

This repository is a collection of scripts to help automate the setup and deployment of n8n on an Ubuntu 22 VPS using Docker, Docker Compose, and Caddy for HTTPS. It also includes Portainer for container management, PostgreSQL for n8n’s database, and instructions for advanced setups like VPN access and DNS-01 challenges.

## 1. Prerequisites
- **Ubuntu 22.x VPS:** A fresh server installation is assumed.
- **Root Access:** Initial scripts require root privileges (to install packages, create users, etc.).
- **DNS A Record**: Point `n8n.yourdomain.com` to your VPS IP. [Guide](https://www.namecheap.com/support/knowledgebase/article.aspx/319/2237/how-to-create-a-cname-record/).
- **DNS-01 Capable Provider (Optional for fully private servers):**
  - If you want to use DNS-01 for Let’s Encrypt, you need a DNS provider (e.g., Namecheap, Cloudflare) that offers an API.
    - Example provided for Namecheap.


## 2. Quick Start

A.  **Download Script:**

  ```bash
  curl -o bootstrap.sh https://raw.githubusercontent.com/DavidMcCauley/n8n_quick_setup/refs/heads/main/scripts/bootstrap.sh
  ```

B.  **Make Executable:**
  ```bash
  chmod +x bootstrap.sh
  ```

C.  **Run (as root or with sudo):**
  ```bash
  ./bootstrap.sh 
  # or
  sudo ./bootstrap.sh 
  ```
D.  **Follow the Prompts:**

  * The script will perform all the checks, upgrades, and git installs, and then it will prompt for the desired user name.
  * If updates are required, the script will perform the updates and a reboot. You must run the script again after the reboot to complete setup.
  * If no updates are found, the script will continue with the setup process.

E.  **Verify:**
  * After each stage, verify that all commands executed as expected, and then press a key to continue to the next stage.

F.  **Complete Setup:**
  * Once all stages are complete, navigate to the `n8n_quick_setup` directory and continue setup.
  ```bash
  cd n8n_quick_setup
  ```

## 3. Repository Directory Structure

```text
n8n_quick_setup/
├── config/
│   ├── .env.example          # Environment variables for n8n
│   ├── Caddyfile             # Caddy reverse proxy configuration
│   ├── docker-compose.yml    # Docker Compose configuration
├── scripts/
│   ├── deploy-n8n.sh         # Deploys n8n and Caddy using Docker Compose
│   ├── setup-docker.sh       # Installs Docker and Docker Compose
│   ├── setup-fail2ban.sh     # Configures Fail2Ban
│   ├── setup-ufw.sh          # Configures UFW
│   ├── setup-user.sh         # Creates a user and configures SSH
│   ├── update-n8n.sh         # Updates n8n and Caddy
├── README.md                 # Instructions for usage
```

## 4. Setup Scripts

### **4.1. `setup-user.sh`**
Creates a non-root user, sets up SSH key authentication, and locks down root login.

```bash
#!/bin/bash

set -e

USERNAME=$1
SSH_PORT=${2:-22}

if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <username> [ssh-port]"
  exit 1
fi

# Create a new user
adduser "$USERNAME"
usermod -aG sudo "$USERNAME"

# Setup SSH key-based authentication
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
cp ~/.ssh/authorized_keys /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# Secure SSH
sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config

systemctl restart ssh
echo "User $USERNAME created and SSH configured on port $SSH_PORT."

```

---

### **4.2. `setup-fail2ban.sh`**
This script installs and configures Fail2Ban.

```bash
#!/bin/bash

set -e

echo "Installing Fail2Ban..."
apt update && apt install -y fail2ban

cat <<EOF >/etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl restart fail2ban
echo "Fail2Ban installed and basic configuration added."
```

---

### **4.3. `setup-ufw.sh`**
This script sets up the UFW firewall.

```bash
#!/bin/bash
# setup-ufw.sh
set -e

echo "Configuring UFW..."
apt install -y ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

echo "UFW configured and enabled."
```

---

### **4.4. `setup-docker.sh`**
This script installs Docker and Docker Compose.

```bash
#!/bin/bash

set -e

echo "Installing Docker..."
apt update && apt install -y docker.io docker-compose

# Add user to Docker group
USERNAME=$1
if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

usermod -aG docker $USERNAME
systemctl enable docker

echo "Docker and Docker Compose installed."
echo "You must log out and back in for group membership to take effect."
```

---

### **4.5. `deploy-n8n.sh`**
This script deploys n8n and Caddy using Docker Compose.

```bash
#!/bin/bash

set -e

# Create Docker volumes
docker volume create caddy_data
docker volume create n8n_data

# Start Docker Compose
docker compose -f config/docker-compose.yml up -d

echo "n8n and Caddy deployed successfully."
```

---

### **4.6. `update-n8n.sh`**
This script updates n8n and Caddy.

```bash
#!/bin/bash

set -e

echo "Updating n8n and Caddy..."
docker compose -f config/docker-compose.yml pull
docker compose -f config/docker-compose.yml down
docker compose -f config/docker-compose.yml up -d

echo "Update complete."
```

---

## 5. Configuration Files

### **5.1. `.env.example`**
Environment variables for n8n.

```dotenv
# ---------------------------------------------------------------------------------
# n8n environment
# ---------------------------------------------------------------------------------
N8N_HOST=n8n.yourdomain.com
N8N_PORT=5678
N8N_PROTOCOL=https

# n8n Basic Auth
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=admin
N8N_BASIC_AUTH_PASSWORD=securepassword

# Encryption key for saved credentials (generate your own via `openssl rand -hex 32`)
N8N_ENCRYPTION_KEY=your-random-key

# ---------------------------------------------------------------------------------
# n8n version
# ---------------------------------------------------------------------------------
N8N_VERSION=latest

# ---------------------------------------------------------------------------------
# PostgreSQL environment
# ---------------------------------------------------------------------------------
POSTGRES_DB=n8n_db
POSTGRES_USER=n8n_user
POSTGRES_PASSWORD=replace_with_secure_password
POSTGRES_PORT=5432

# ---------------------------------------------------------------------------------
# Database Type (let n8n know to use PostgreSQL)
# ---------------------------------------------------------------------------------
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
DB_POSTGRESDB_USER=${POSTGRES_USER}
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
DB_POSTGRESDB_PORT=${POSTGRES_PORT}

# ---------------------------------------------------------------------------------
# Caddy environment
# ---------------------------------------------------------------------------------
DOMAIN_NAME=n8n.yourdomain.com
EMAIL=youremail@example.com

# ---------------------------------------------------------------------------------
# Use Portainer Community Edition (CE)
# ---------------------------------------------------------------------------------
PORTAINER_VERSION=latest
```

---

### **5.2. `docker-compose.yml`**
A multi-service stack with PostgreSQL, n8n, Caddy, and Portainer.

```yaml
services:

  # ----------------------------------------------------------------------------
  # PostgreSQL database (for n8n)
  # ----------------------------------------------------------------------------
  postgres:
    image: postgres:15
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    volumes:
      - n8n_postgres_data:/var/lib/postgresql/data

  # ----------------------------------------------------------------------------
  # n8n workflow automation
  # ----------------------------------------------------------------------------
  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      # n8n basics
      - N8N_HOST=${N8N_HOST}
      - N8N_PORT=${N8N_PORT}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      
      # Basic Auth
      - N8N_BASIC_AUTH_ACTIVE=${N8N_BASIC_AUTH_ACTIVE}
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}

      # Encryption Key
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}

      # Database configuration
      - DB_TYPE=${DB_TYPE}
      - DB_POSTGRESDB_HOST=${DB_POSTGRESDB_HOST}
      - DB_POSTGRESDB_DATABASE=${DB_POSTGRESDB_DATABASE}
      - DB_POSTGRESDB_USER=${DB_POSTGRESDB_USER}
      - DB_POSTGRESDB_PASSWORD=${DB_POSTGRESDB_PASSWORD}
      - DB_POSTGRESDB_PORT=${DB_POSTGRESDB_PORT}

    volumes:
      - n8n_data:/home/node/.n8n

  # ----------------------------------------------------------------------------
  # Caddy for reverse-proxy and auto-TLS
  # ----------------------------------------------------------------------------
  caddy:
    image: caddy:latest
    restart: unless-stopped
    ports:
      - "80:80"    # HTTP
      - "443:443"  # HTTPS
    volumes:
      - caddy_data:/data
      - ./config/Caddyfile:/etc/caddy/Caddyfile

  # ----------------------------------------------------------------------------
  # Portainer for container management
  # ----------------------------------------------------------------------------
  portainer:
    image: portainer/portainer-ce:${PORTAINER_VERSION:-latest}
    container_name: portainer
    restart: unless-stopped
    ports:
      - "9000:9000"  # Expose Portainer on port 9000
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - portainer_data:/data

volumes:
  n8n_postgres_data:
  n8n_data:
  caddy_data:
  portainer_data:
```

---

### **5.3. `Caddyfile`**
Defines the Caddy reverse proxy configuration.

```caddyfile
n8n.yourdomain.com {
    reverse_proxy n8n:5678 {
        flush_interval -1
    }
}
```

If you are using DNS-01 for your certificate generation you must replace this with:

```caddyfile
n8n.yourdomain.com {
    tls {
        dns namecheap {
          api_user    ${NAMECHEAP_USERNAME}
          api_key     ${NAMECHEAP_API_KEY}
          api_ip      ${NAMECHEAP_SOURCEIP}
        }
    }
    reverse_proxy n8n:5678 {
        flush_interval -1
    }
}
```

## Updating n8n
To update n8n:
```bash
./scripts/update-n8n.sh
```

## Notes
- Ensure your `.env` file has strong passwords and an encryption key.
- Backup Docker volumes before updating.

## **Backup & Restore**

### **Backing up PostgreSQL**

Backing up your data is crucial. One simple approach is to **dump** the database with `pg_dump` in a container:

```bash
docker exec postgres pg_dump -U "${POSTGRES_USER}" "${POSTGRES_DB}" > n8n_dump.sql
```
You can store that `n8n_dump.sql` file off-server or in versioned backups.

### **Restoring PostgreSQL**

```bash
docker exec -i postgres psql -U "${POSTGRES_USER}" "${POSTGRES_DB}" < n8n_dump.sql
```

### **Volumes Backup**
```bash
# Example: backup n8n_data volume
docker run --rm -v n8n_data:/data -v $(pwd):/backup ubuntu \
    tar cvf /backup/n8n_data_backup.tar /data
```

> **Tip**: For a more automated approach, you can run `pg_dump`/`psql` in a scheduled script or use a Docker-based backup container.

---

## **Additional Best Practices**

1. **Check Container Logs**:  
   ```bash
   docker compose -f config/docker-compose.yml logs -f
   ```
2. **Enable Automatic Security Updates**:
   ```bash
   sudo apt install unattended-upgrades -y
   sudo dpkg-reconfigure --priority=low unattended-upgrades
   ```
3. **Set Up Monitoring**:
   - Tools like **Netdata** or **Prometheus** + **Grafana** can help you track resource usage.
4. **Harden PostgreSQL**:
   - Expose the port only internally (Compose does this by default since no external `ports:` is mapped for `postgres`).
   - Use strong DB credentials.

---

## **Final Steps**

1. **Update or create your `.env`** with **Postgres** values.  
2. **Run** the standard setup scripts in order (`setup-user.sh`, etc.).  
3. **Deploy** the updated stack:
   ```bash
   ./scripts/deploy-n8n.sh
   ```
4. **Confirm** your containers are up:
   ```bash
   docker compose -f config/docker-compose.yml ps
   ```
5. **Access** n8n at:
   ```
   https://n8n.yourdomain.com
   ```
6. **Log in** with your Basic Auth credentials from `.env` and start automating!

---
