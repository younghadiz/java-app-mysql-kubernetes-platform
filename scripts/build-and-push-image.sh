#!/usr/bin/env bash

set -Eeuo pipefail

DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
IMAGE_NAME="${IMAGE_NAME:-java-mysql-app}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"

if [[ -z "${DOCKERHUB_USERNAME}" ]]; then
  echo "ERROR: DOCKERHUB_USERNAME is required."
  exit 1
fi

FULL_IMAGE="${DOCKERHUB_USERNAME}/${IMAGE_NAME}:${IMAGE_TAG}"

echo "Running application tests..."
docker build \
  --target builder \
  --tag "${IMAGE_NAME}-builder:${IMAGE_TAG}" \
  .

echo "Building runtime image ${FULL_IMAGE}..."
docker build \
  --tag "${FULL_IMAGE}" \
  .

if command -v trivy >/dev/null 2>&1; then
  echo "Scanning ${FULL_IMAGE}..."
  trivy image \
    --severity HIGH,CRITICAL \
    --ignore-unfixed \
    --exit-code 0 \
    "${FULL_IMAGE}"
else
  echo "WARNING: Trivy is not installed; skipping image vulnerability scan."
fi

echo "Pushing ${FULL_IMAGE}..."
docker push "${FULL_IMAGE}"

echo "Successfully published ${FULL_IMAGE}."