#!/bin/bash
set -Eeuo pipefail

IMAGE="aws-docker-cicd:staging"
CONTAINER_NAME="devops-app-rollback-test"
HEALTH_URL="http://127.0.0.1:5002/health"
MAX_ATTEMPTS=4
RETRY_INTERVAL=2
TEST_CONTAINER_CREATED=0

cleanup() {
  if [ "$TEST_CONTAINER_CREATED" -eq 1 ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Checking the known-good staging image..."
PREVIOUS_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE")

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  echo "ERROR: Test container already exists; refusing to modify it." >&2
  exit 1
fi

echo "Starting an intentionally failing test container..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1:5002:5000 \
  "$IMAGE" /bin/sh -c 'exit 1' >/dev/null
TEST_CONTAINER_CREATED=1

sleep 2

if [ "$(docker inspect --format '{{.State.Status}}' "$CONTAINER_NAME")" != "exited" ]; then
  echo "ERROR: The test container did not fail as expected." >&2
  exit 1
fi

echo "Confirmed: the test container exited."

echo "Checking that health checks fail for the broken container..."
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if curl --fail --silent "$HEALTH_URL" >/dev/null; then
    echo "ERROR: The broken container unexpectedly passed its health check." >&2
    exit 1
  fi

  echo "Health check failed as expected ($attempt/$MAX_ATTEMPTS)."
  sleep "$RETRY_INTERVAL"
done

echo "Restoring the known-good staging image..."
docker rm -f "$CONTAINER_NAME" >/dev/null
TEST_CONTAINER_CREATED=0

docker run -d \
  --name "$CONTAINER_NAME" \
  -p 127.0.0.1:5002:5000 \
  "$PREVIOUS_IMAGE_ID" >/dev/null
TEST_CONTAINER_CREATED=1

echo "Waiting for the restored container to become healthy..."
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  if curl --fail --silent "$HEALTH_URL"; then
    echo
    echo "SUCCESS: The restored image is healthy."
    exit 0
  fi

  echo "Restored image is not ready ($attempt/$MAX_ATTEMPTS)."
  sleep "$RETRY_INTERVAL"
done

echo "ERROR: The restored image failed its health checks." >&2
docker logs --tail 100 "$CONTAINER_NAME" >&2 || true
exit 1
