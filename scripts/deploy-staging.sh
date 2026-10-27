#!/bin/bash
set -e

APP_DIR="/home/deploy/apps/staging"
CONTAINER_NAME="devops-app-staging"
IMAGE="aws-docker-cicd:staging"
PREVIOUS_IMAGE="aws-docker-cicd:staging-previous"
HEALTH_URL="http://127.0.0.1:5001/health"
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

rollback_staging() {
  echo "Rolling back staging to the previous image..."

  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  if [ -z "$PREVIOUS_IMAGE_ID" ]; then
    echo "ERROR: No previous image is available for rollback." >&2
    return 1
  fi

  docker tag "$PREVIOUS_IMAGE_ID" "$IMAGE"

  if ! docker run -d \
    --name "$CONTAINER_NAME" \
    -p 127.0.0.1:5001:5000 \
    --restart unless-stopped \
    "$IMAGE"; then
    echo "ERROR: Could not restart the previous staging image." >&2
    return 1
  fi

  if wait_for_health "$HEALTH_URL" "$MAX_ATTEMPTS"; then
    echo "Rollback successful. Previous staging version is healthy."
    return 0
  fi

  echo "ERROR: The previous staging version also failed its health check." >&2
  docker logs --tail 100 "$CONTAINER_NAME" >&2 || true
  return 1
}

echo "Starting staging deployment..."
cd "$APP_DIR"

echo "Updating source from develop..."
git fetch origin
git checkout develop
git reset --hard origin/develop

echo "Preserving the current staging image..."
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker tag "$IMAGE" "$PREVIOUS_IMAGE"
  PREVIOUS_IMAGE_ID=$(docker image inspect \
    --format '{{.Id}}' "$PREVIOUS_IMAGE")
else
  echo "No existing staging image found."
fi

echo "Building the new staging image..."
docker build -t "$IMAGE" .

echo "Stopping the current staging container..."
docker stop "$CONTAINER_NAME" || true
docker rm "$CONTAINER_NAME" || true

echo "Starting the new staging container..."
if ! docker run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1:5001:5000 \
  --restart unless-stopped \
  "$IMAGE"; then
  echo "ERROR: New staging container failed to start." >&2
  rollback_staging || true
  exit 1
fi

echo "Checking the new staging deployment..."
if wait_for_health "$HEALTH_URL" "$MAX_ATTEMPTS"; then
  echo "Staging deployment successful."
  exit 0
fi

echo "ERROR: New staging version failed its health checks." >&2
docker logs --tail 100 "$CONTAINER_NAME" >&2 || true

rollback_staging || true
exit 1
