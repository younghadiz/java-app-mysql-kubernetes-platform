#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd
)"

REPOSITORY_ROOT="$(
  cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1
  pwd
)"

BASE_DIRECTORY="${REPOSITORY_ROOT}/kubernetes/base"

NAMESPACE="${NAMESPACE:-java-mysql}"
APP_NAME="${APP_NAME:-java-app}"
APP_SECRET_NAME="${APP_SECRET_NAME:-java-app-secret}"
REGISTRY_SECRET_NAME="${REGISTRY_SECRET_NAME:-dockerhub-registry}"
MYSQL_PRIMARY_STATEFULSET="${MYSQL_PRIMARY_STATEFULSET:-mysql-primary}"

REQUIRE_REGISTRY_SECRET="${REQUIRE_REGISTRY_SECRET:-true}"
WAIT_FOR_MYSQL="${WAIT_FOR_MYSQL:-true}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"

log() {
  printf '[INFO] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1" >&2
}

error() {
  printf '[ERROR] %s\n' "$1" >&2
}

show_diagnostics() {
  local exit_code=$?

  if (( exit_code == 0 )); then
    return
  fi

  error "Deployment failed with exit code ${exit_code}."

  kubectl get pods \
    --namespace "${NAMESPACE}" \
    --output=wide \
    2>/dev/null || true

  kubectl get events \
    --namespace "${NAMESPACE}" \
    --sort-by='.lastTimestamp' \
    2>/dev/null | tail -n 30 || true

  kubectl describe deployment "${APP_NAME}" \
    --namespace "${NAMESPACE}" \
    2>/dev/null || true

  kubectl logs \
    --namespace "${NAMESPACE}" \
    --selector "app.kubernetes.io/name=${APP_NAME}" \
    --all-containers=true \
    --prefix=true \
    --tail=100 \
    2>/dev/null || true
}

trap show_diagnostics EXIT

required_files=(
  "${BASE_DIRECTORY}/namespace.yaml"
  "${BASE_DIRECTORY}/configmap.yaml"
  "${BASE_DIRECTORY}/service.yaml"
  "${BASE_DIRECTORY}/deployment.yaml"
  "${BASE_DIRECTORY}/pdb.yaml"
)

if ! command -v kubectl >/dev/null 2>&1; then
  error "kubectl is not installed or is not available in PATH."
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  error "The Kubernetes cluster is not reachable."
  error "Check the active kubectl context and cluster status."
  exit 1
fi

for required_file in "${required_files[@]}"; do
  if [[ ! -f "${required_file}" ]]; then
    error "Required manifest does not exist: ${required_file}"
    exit 1
  fi
done

CURRENT_CONTEXT="$(kubectl config current-context)"

log "Kubernetes context: ${CURRENT_CONTEXT}"
log "Target namespace: ${NAMESPACE}"
log "Applying namespace manifest."

kubectl apply \
  --filename "${BASE_DIRECTORY}/namespace.yaml"

if ! kubectl get secret "${APP_SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  >/dev/null 2>&1; then
  error "Application Secret '${APP_SECRET_NAME}' does not exist."
  error "Run ./scripts/create-local-secrets.sh first."
  exit 1
fi

log "Found application Secret '${APP_SECRET_NAME}'."

if [[ "${REQUIRE_REGISTRY_SECRET}" == "true" ]]; then
  if ! kubectl get secret "${REGISTRY_SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    >/dev/null 2>&1; then
    error "Registry Secret '${REGISTRY_SECRET_NAME}' does not exist."
    error "Provide Docker Hub variables and run:"
    error "./scripts/create-local-secrets.sh"
    exit 1
  fi

  log "Found registry Secret '${REGISTRY_SECRET_NAME}'."
else
  log "Registry Secret validation is disabled."
fi

if [[ "${WAIT_FOR_MYSQL}" == "true" ]]; then
  if ! kubectl get statefulset "${MYSQL_PRIMARY_STATEFULSET}" \
    --namespace "${NAMESPACE}" \
    >/dev/null 2>&1; then
    error "MySQL StatefulSet '${MYSQL_PRIMARY_STATEFULSET}' does not exist."
    error "Deploy MySQL before deploying the Java application."
    exit 1
  fi

  log "Waiting for MySQL primary StatefulSet to become ready."

  kubectl rollout status \
    "statefulset/${MYSQL_PRIMARY_STATEFULSET}" \
    --namespace "${NAMESPACE}" \
    --timeout="${ROLLOUT_TIMEOUT}"

  if ! kubectl get service mysql-primary \
    --namespace "${NAMESPACE}" \
    >/dev/null 2>&1; then
    error "MySQL Service 'mysql-primary' does not exist."
    exit 1
  fi

  log "MySQL primary and Service are available."
else
  warn "MySQL readiness validation is disabled."
fi

log "Validating Kubernetes manifests."

kubectl apply \
  --filename "${BASE_DIRECTORY}/configmap.yaml" \
  --dry-run=server

kubectl apply \
  --filename "${BASE_DIRECTORY}/service.yaml" \
  --dry-run=server

kubectl apply \
  --filename "${BASE_DIRECTORY}/deployment.yaml" \
  --dry-run=server

kubectl apply \
  --filename "${BASE_DIRECTORY}/pdb.yaml" \
  --dry-run=server

log "Applying application configuration."

kubectl apply \
  --filename "${BASE_DIRECTORY}/configmap.yaml"

log "Applying application Service."

kubectl apply \
  --filename "${BASE_DIRECTORY}/service.yaml"

log "Applying application Deployment."

kubectl apply \
  --filename "${BASE_DIRECTORY}/deployment.yaml"

log "Applying PodDisruptionBudget."

kubectl apply \
  --filename "${BASE_DIRECTORY}/pdb.yaml"

log "Waiting for application rollout."

kubectl rollout status \
  "deployment/${APP_NAME}" \
  --namespace "${NAMESPACE}" \
  --timeout="${ROLLOUT_TIMEOUT}"

log "Verifying Service endpoints."

kubectl get endpointslice \
  --namespace "${NAMESPACE}" \
  --selector "kubernetes.io/service-name=${APP_NAME}"

log "Application resources."

kubectl get deployment,pod,service,pdb \
  --namespace "${NAMESPACE}" \
  --selector "app.kubernetes.io/name=${APP_NAME}" \
  --output=wide

trap - EXIT

log "Java application deployment completed successfully." 