#!/bin/bash

set -e

echo "Updating n8n and Caddy..."
docker compose -f config/docker-compose.yml pull
docker compose -f config/docker-compose.yml down
docker compose -f config/docker-compose.yml up -d

echo "Update complete."
