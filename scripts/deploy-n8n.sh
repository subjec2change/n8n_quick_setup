#!/bin/bash

set -e

# Create Docker volumes
docker volume create caddy_data
docker volume create n8n_data

# Start Docker Compose
docker compose -f config/docker-compose.yml up -d

echo "n8n and Caddy deployed successfully."
