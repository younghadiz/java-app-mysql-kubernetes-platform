#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-java-mysql}"
SECRET_NAME="${SECRET_NAME:-java-app-secret}"
REGISTRY_SECRET_NAME="${REGISTRY_SECRET_NAME:-dockerhub-registry}"

DB_USER="${DB_USER:-}"
DB_PASSWORD="${DB_PASSWORD:-}"

DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
DOCKERHUB_EMAIL="${DOCKERHUB_EMAIL:-}"

log() {
  printf '[INFO] %s\n' "$1"
}

error() {
  printf '[ERROR] %s\n' "$1" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

if ! command_exists kubectl; then
  error "kubectl is not installed or is not available in PATH."
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  error "Kubernetes is not reachable. Check your kubectl context."
  exit 1
fi

CURRENT_CONTEXT="$(kubectl config current-context)"

log "Current Kubernetes context: ${CURRENT_CONTEXT}"
log "Target namespace: ${NAMESPACE}"

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  error "Namespace '${NAMESPACE}' does not exist."
  error "Deploy MySQL first or create the namespace before running this script."
  exit 1
fi

if [[ -z "${DB_USER}" ]]; then
  read -r -p "Database username: " DB_USER
fi

if [[ -z "${DB_PASSWORD}" ]]; then
  read -r -s -p "Database password: " DB_PASSWORD
  printf '\n'
fi

if [[ -z "${DB_USER}" ]]; then
  error "Database username cannot be empty."
  exit 1
fi

if [[ -z "${DB_PASSWORD}" ]]; then
  error "Database password cannot be empty."
  exit 1
fi

if (( ${#DB_PASSWORD} > 32 )); then
  error "Database password cannot be longer than 32 characters."
  exit 1
fi

log "Creating or updating application Secret '${SECRET_NAME}'."

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=DB_USER="${DB_USER}" \
  --from-literal=DB_PWD="${DB_PASSWORD}" \
  --dry-run=client \
  --output=yaml \
  | kubectl apply --filename -

log "Created or updated application Secret '${SECRET_NAME}'."

if [[ -n "${DOCKERHUB_USERNAME}" || -n "${DOCKERHUB_TOKEN}" ]]; then
  if [[ -z "${DOCKERHUB_USERNAME}" || -z "${DOCKERHUB_TOKEN}" ]]; then
    error "Both DOCKERHUB_USERNAME and DOCKERHUB_TOKEN must be provided."
    exit 1
  fi

  log "Creating or updating Docker Hub registry Secret '${REGISTRY_SECRET_NAME}'."

  kubectl create secret docker-registry "${REGISTRY_SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --docker-server="https://index.docker.io/v1/" \
    --docker-username="${DOCKERHUB_USERNAME}" \
    --docker-password="${DOCKERHUB_TOKEN}" \
    --docker-email="${DOCKERHUB_EMAIL}" \
    --dry-run=client \
    --output=yaml \
    | kubectl apply --filename -

  log "Created or updated registry Secret '${REGISTRY_SECRET_NAME}'."
else
  log "Docker Hub registry variables were not provided."
  log "Skipping imagePullSecret creation."
fi

log "Secret creation completed successfully." 