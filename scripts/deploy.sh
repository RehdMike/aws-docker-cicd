#!/bin/bash
set -e

APP_DIR="/home/deploy/apps/production"
CONTAINER_NAME="devops-app"
IMAGE="aws-docker-cicd:latest"
PREVIOUS_IMAGE="aws-docker-cicd:production-previous"
HEALTH_URL="http://127.0.0.1:5000/health"
MAX_ATTEMPTS=10
RETRY_INTERVAL=3
PREVIOUS_IMAGE_ID=""

wait_for_health() {
  local url="$1"
  local attempts="$2"

  for attempt in $(seq 1 "$attempts"); do
    if curl --fail --silent "$url"; then
      echo
      echo "Health check passed on attempt $attempt/$attempts."
      return 0
    fi

    if [ "$attempt" -lt "$attempts" ]; then
      echo "Health check attempt $attempt/$attempts failed."
      echo "Retrying in ${RETRY_INTERVAL} seconds..."
      sleep "$RETRY_INTERVAL"
    fi
  done

  return 1
}

rollback_production() {
  echo "Rolling back production to the previous image..."

  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  if [ -z "$PREVIOUS_IMAGE_ID" ]; then
    echo "ERROR: No previous image is available for rollback." >&2
    return 1
  fi

  docker tag "$PREVIOUS_IMAGE_ID" "$IMAGE"

  if ! docker run -d \
    --name "$CONTAINER_NAME" \
    -p 127.0.0.1:5000:5000 \
    --restart unless-stopped \
    "$IMAGE"; then
    echo "ERROR: Could not restart the previous production image." >&2
    return 1
  fi

  if wait_for_health "$HEALTH_URL" "$MAX_ATTEMPTS"; then
    echo "Rollback successful. Previous production version is healthy."
    return 0
  fi

  echo "ERROR: The previous production version also failed its health check." >&2
  docker logs --tail 100 "$CONTAINER_NAME" >&2 || true
  return 1
}

echo "Starting production deployment..."
cd "$APP_DIR"

echo "Updating source from main..."
git fetch origin
git checkout main
git reset --hard origin/main

echo "Preserving the current production image..."
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker tag "$IMAGE" "$PREVIOUS_IMAGE"
  PREVIOUS_IMAGE_ID=$(docker image inspect \
    --format '{{.Id}}' "$PREVIOUS_IMAGE")
else
  echo "No existing production image found."
fi

echo "Building the new production image..."
docker build -t "$IMAGE" .

echo "Stopping the current production container..."
docker stop "$CONTAINER_NAME" || true
docker rm "$CONTAINER_NAME" || true

echo "Starting the new production container..."
if ! docker run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1:5000:5000 \
  --restart unless-stopped \
  "$IMAGE"; then
  echo "ERROR: New production container failed to start." >&2
  rollback_production || true
  exit 1
fi

echo "Checking the new production deployment..."
if wait_for_health "$HEALTH_URL" "$MAX_ATTEMPTS"; then
  echo "Production deployment successful."
  exit 0
fi

echo "ERROR: New production version failed its health checks." >&2
docker logs --tail 100 "$CONTAINER_NAME" >&2 || true

rollback_production || true
exit 1
