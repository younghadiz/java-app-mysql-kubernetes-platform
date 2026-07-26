#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-java-mysql}"
APP_HOST="${APP_HOST:-my-java-app.com}"

MYSQL_RELEASE="${MYSQL_RELEASE:-mysql}"
JAVA_RELEASE="${JAVA_RELEASE:-java-app}"

JAVA_DEPLOYMENT="${JAVA_DEPLOYMENT:-java-app}"
JAVA_SERVICE="${JAVA_SERVICE:-java-app}"
JAVA_INGRESS="${JAVA_INGRESS:-java-app}"

MYSQL_PRIMARY_STATEFULSET="${MYSQL_PRIMARY_STATEFULSET:-mysql-primary}"
MYSQL_SECONDARY_STATEFULSET="${MYSQL_SECONDARY_STATEFULSET:-mysql-secondary}"

EXPECTED_JAVA_REPLICAS="${EXPECTED_JAVA_REPLICAS:-2}"
EXPECTED_MYSQL_PRIMARY_REPLICAS="${EXPECTED_MYSQL_PRIMARY_REPLICAS:-1}"
EXPECTED_MYSQL_SECONDARY_REPLICAS="${EXPECTED_MYSQL_SECONDARY_REPLICAS:-2}"

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
EXPECTED_HTTP_STATUS="${EXPECTED_HTTP_STATUS:-200}"

LOCAL_INGRESS_PORT="${LOCAL_INGRESS_PORT:-18080}"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""

fail() {
  echo
  echo "VALIDATION FAILED: $1" >&2
  exit 1
}

info() {
  echo
  echo "$1"
}

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]] &&
     kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi

  if [[ -n "${PORT_FORWARD_LOG}" ]] &&
     [[ -f "${PORT_FORWARD_LOG}" ]]; then
    rm -f "${PORT_FORWARD_LOG}"
  fi
}

on_error() {
  local exit_code=$?

  echo
  echo "Validation stopped on or near line ${BASH_LINENO[0]}." >&2

  exit "${exit_code}"
}

resource_exists() {
  local resource_type="$1"
  local resource_name="$2"

  kubectl get "${resource_type}" "${resource_name}" \
    --namespace "${NAMESPACE}" \
    >/dev/null 2>&1
}

validate_helm_release() {
  local release_name="$1"
  local release_status

  release_status="$(
    helm status "${release_name}" \
      --namespace "${NAMESPACE}" \
      --output json \
      2>/dev/null \
      | jq -r '.info.status // empty'
  )"

  if [[ -z "${release_status}" ]]; then
    fail "Helm release ${release_name} does not exist in namespace ${NAMESPACE}."
  fi

  if [[ "${release_status}" != "deployed" ]]; then
    fail "Helm release ${release_name} has status ${release_status}, expected deployed."
  fi

  echo "Helm release ${release_name}: ${release_status}"
}

validate_statefulset_replicas() {
  local statefulset_name="$1"
  local expected_replicas="$2"

  local ready_replicas
  local desired_replicas

  ready_replicas="$(
    kubectl get statefulset "${statefulset_name}" \
      --namespace "${NAMESPACE}" \
      --output=jsonpath='{.status.readyReplicas}'
  )"

  desired_replicas="$(
    kubectl get statefulset "${statefulset_name}" \
      --namespace "${NAMESPACE}" \
      --output=jsonpath='{.spec.replicas}'
  )"

  ready_replicas="${ready_replicas:-0}"
  desired_replicas="${desired_replicas:-0}"

  if [[ "${desired_replicas}" != "${expected_replicas}" ]]; then
    fail "StatefulSet ${statefulset_name} expects ${desired_replicas} replicas, but validation expects ${expected_replicas}."
  fi

  if [[ "${ready_replicas}" != "${expected_replicas}" ]]; then
    fail "StatefulSet ${statefulset_name} has ${ready_replicas}/${expected_replicas} ready replicas."
  fi

  echo "StatefulSet ${statefulset_name}: ${ready_replicas}/${expected_replicas} ready"
}

trap cleanup EXIT
trap on_error ERR

info "1. Validating required command-line tools..."

for command in kubectl helm jq curl awk grep mktemp; do
  command -v "${command}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command}"
done

echo "Required tools are installed."

info "2. Validating Kubernetes context..."

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

if [[ -z "${CURRENT_CONTEXT}" ]]; then
  fail "No active Kubernetes context is configured."
fi

echo "Current context: ${CURRENT_CONTEXT}"

info "3. Validating Kubernetes cluster connectivity..."

kubectl cluster-info >/dev/null 2>&1 \
  || fail "Unable to connect to the Kubernetes cluster."

echo "Kubernetes API is reachable."

info "4. Validating node readiness..."

NOT_READY_NODES="$(
  kubectl get nodes \
    --no-headers \
    | awk '$2 != "Ready" { print $1 }'
)"

if [[ -n "${NOT_READY_NODES}" ]]; then
  fail "The following nodes are not Ready: ${NOT_READY_NODES}"
fi

kubectl get nodes

info "5. Validating namespace..."

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Namespace ${NAMESPACE} does not exist."

echo "Namespace ${NAMESPACE} exists."

info "6. Validating Helm releases..."

validate_helm_release "${MYSQL_RELEASE}"
validate_helm_release "${JAVA_RELEASE}"

info "7. Validating MySQL StatefulSet rollouts..."

resource_exists statefulset "${MYSQL_PRIMARY_STATEFULSET}" \
  || fail "StatefulSet ${MYSQL_PRIMARY_STATEFULSET} does not exist."

resource_exists statefulset "${MYSQL_SECONDARY_STATEFULSET}" \
  || fail "StatefulSet ${MYSQL_SECONDARY_STATEFULSET} does not exist."

kubectl rollout status \
  "statefulset/${MYSQL_PRIMARY_STATEFULSET}" \
  --namespace "${NAMESPACE}" \
  --timeout="${ROLLOUT_TIMEOUT}"

kubectl rollout status \
  "statefulset/${MYSQL_SECONDARY_STATEFULSET}" \
  --namespace "${NAMESPACE}" \
  --timeout="${ROLLOUT_TIMEOUT}"

validate_statefulset_replicas \
  "${MYSQL_PRIMARY_STATEFULSET}" \
  "${EXPECTED_MYSQL_PRIMARY_REPLICAS}"

validate_statefulset_replicas \
  "${MYSQL_SECONDARY_STATEFULSET}" \
  "${EXPECTED_MYSQL_SECONDARY_REPLICAS}"

info "8. Validating MySQL container images..."

MYSQL_IMAGES="$(
  kubectl get pods \
    --namespace "${NAMESPACE}" \
    --selector app.kubernetes.io/instance=mysql \
    --output=jsonpath='{range .items[*]}{.metadata.name}{"="}{.spec.containers[0].image}{"\n"}{end}'
)"

if [[ -z "${MYSQL_IMAGES}" ]]; then
  fail "No MySQL pods were found."
fi

echo "${MYSQL_IMAGES}"

if grep -q ':latest$' <<<"${MYSQL_IMAGES}"; then
  fail "At least one MySQL pod is using the mutable latest image tag."
fi

info "9. Validating PersistentVolumeClaims..."

PVC_COUNT="$(
  kubectl get pvc \
    --namespace "${NAMESPACE}" \
    --no-headers \
    2>/dev/null \
    | wc -l \
    | tr -d ' '
)"

if [[ "${PVC_COUNT}" == "0" ]]; then
  fail "No PersistentVolumeClaims were found in namespace ${NAMESPACE}."
fi

UNBOUND_PVCS="$(
  kubectl get pvc \
    --namespace "${NAMESPACE}" \
    --no-headers \
    | awk '$2 != "Bound" { print $1 }'
)"

if [[ -n "${UNBOUND_PVCS}" ]]; then
  fail "The following PVCs are not Bound: ${UNBOUND_PVCS}"
fi

kubectl get pvc --namespace "${NAMESPACE}"

info "10. Validating MySQL primary connectivity..."

MYSQL_PRIMARY_POD="$(
  kubectl get pods \
    --namespace "${NAMESPACE}" \
    --selector app.kubernetes.io/instance=mysql,app.kubernetes.io/component=primary \
    --field-selector=status.phase=Running \
    --output=jsonpath='{.items[0].metadata.name}' \
    2>/dev/null \
    || true
)"

if [[ -z "${MYSQL_PRIMARY_POD}" ]]; then
  fail "No running MySQL primary pod was found."
fi

kubectl exec \
  --namespace "${NAMESPACE}" \
  --container mysql \
  "${MYSQL_PRIMARY_POD}" \
  -- bash -ec '
    password_aux="${MYSQL_ROOT_PASSWORD:-}"

    if [[ -n "${MYSQL_ROOT_PASSWORD_FILE:-}" ]] &&
       [[ -f "${MYSQL_ROOT_PASSWORD_FILE}" ]]; then
      password_aux="$(cat "${MYSQL_ROOT_PASSWORD_FILE}")"
    fi

    MYSQL_PWD="${password_aux}" mysqladmin ping \
      --user=root \
      --silent
  ' >/dev/null \
  || fail "Unable to connect to the MySQL primary."

echo "MySQL primary is accepting connections."

info "11. Validating Java application rollout..."

resource_exists deployment "${JAVA_DEPLOYMENT}" \
  || fail "Deployment ${JAVA_DEPLOYMENT} does not exist."

kubectl rollout status \
  "deployment/${JAVA_DEPLOYMENT}" \
  --namespace "${NAMESPACE}" \
  --timeout="${ROLLOUT_TIMEOUT}"

AVAILABLE_REPLICAS="$(
  kubectl get deployment "${JAVA_DEPLOYMENT}" \
    --namespace "${NAMESPACE}" \
    --output=jsonpath='{.status.availableReplicas}'
)"

READY_REPLICAS="$(
  kubectl get deployment "${JAVA_DEPLOYMENT}" \
    --namespace "${NAMESPACE}" \
    --output=jsonpath='{.status.readyReplicas}'
)"

AVAILABLE_REPLICAS="${AVAILABLE_REPLICAS:-0}"
READY_REPLICAS="${READY_REPLICAS:-0}"

if [[ "${AVAILABLE_REPLICAS}" != "${EXPECTED_JAVA_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_JAVA_REPLICAS} available Java replicas, found ${AVAILABLE_REPLICAS}."
fi

if [[ "${READY_REPLICAS}" != "${EXPECTED_JAVA_REPLICAS}" ]]; then
  fail "Expected ${EXPECTED_JAVA_REPLICAS} ready Java replicas, found ${READY_REPLICAS}."
fi

echo "Java deployment: ${READY_REPLICAS}/${EXPECTED_JAVA_REPLICAS} ready"

info "12. Validating Java Service..."

resource_exists service "${JAVA_SERVICE}" \
  || fail "Service ${JAVA_SERVICE} does not exist."

SERVICE_CLUSTER_IP="$(
  kubectl get service "${JAVA_SERVICE}" \
    --namespace "${NAMESPACE}" \
    --output=jsonpath='{.spec.clusterIP}'
)"

if [[ -z "${SERVICE_CLUSTER_IP}" ]] ||
   [[ "${SERVICE_CLUSTER_IP}" == "None" ]]; then
  fail "Service ${JAVA_SERVICE} has no valid ClusterIP."
fi

echo "Service ClusterIP: ${SERVICE_CLUSTER_IP}"

info "13. Validating Service endpoints..."

ENDPOINTS="$(
  kubectl get endpoints "${JAVA_SERVICE}" \
    --namespace "${NAMESPACE}" \
    --output=jsonpath='{.subsets[*].addresses[*].ip}' \
    2>/dev/null \
    || true
)"

if [[ -z "${ENDPOINTS}" ]]; then
  fail "Service ${JAVA_SERVICE} has no ready endpoints."
fi

echo "Ready endpoints: ${ENDPOINTS}"

info "14. Validating Ingress..."

resource_exists ingress "${JAVA_INGRESS}" \
  || fail "Ingress ${JAVA_INGRESS} does not exist."

INGRESS_HOSTS="$(
  kubectl get ingress "${JAVA_INGRESS}" \
    --namespace "${NAMESPACE}" \
    --output=jsonpath='{.spec.rules[*].host}'
)"

if ! grep -qw "${APP_HOST}" <<<"${INGRESS_HOSTS}"; then
  fail "Ingress ${JAVA_INGRESS} does not contain expected host ${APP_HOST}. Found: ${INGRESS_HOSTS}"
fi

echo "Ingress host: ${APP_HOST}"

info "15. Locating the Ingress controller..."

INGRESS_CONTROLLER_DETAILS="$(
  kubectl get service \
    --all-namespaces \
    --selector app.kubernetes.io/component=controller \
    --output=jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    | awk '$2 ~ /ingress-nginx-controller/ { print $1, $2; exit }'
)"

INGRESS_CONTROLLER_NAMESPACE="$(
  awk '{ print $1 }' <<<"${INGRESS_CONTROLLER_DETAILS}"
)"

INGRESS_CONTROLLER_SERVICE="$(
  awk '{ print $2 }' <<<"${INGRESS_CONTROLLER_DETAILS}"
)"

if [[ -z "${INGRESS_CONTROLLER_NAMESPACE}" ]] ||
   [[ -z "${INGRESS_CONTROLLER_SERVICE}" ]]; then
  fail "Unable to locate the ingress-nginx controller Service."
fi

echo "Ingress controller namespace: ${INGRESS_CONTROLLER_NAMESPACE}"
echo "Ingress controller Service: ${INGRESS_CONTROLLER_SERVICE}"

info "16. Creating a temporary Ingress port-forward..."

PORT_FORWARD_LOG="$(mktemp)"

kubectl port-forward \
  --namespace "${INGRESS_CONTROLLER_NAMESPACE}" \
  "service/${INGRESS_CONTROLLER_SERVICE}" \
  "${LOCAL_INGRESS_PORT}:80" \
  >"${PORT_FORWARD_LOG}" 2>&1 &

PORT_FORWARD_PID=$!

PORT_FORWARD_READY=false

for _ in {1..30}; do
  if grep -q "Forwarding from" "${PORT_FORWARD_LOG}"; then
    PORT_FORWARD_READY=true
    break
  fi

  if ! kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    cat "${PORT_FORWARD_LOG}" >&2
    fail "The Ingress controller port-forward stopped unexpectedly."
  fi

  sleep 1
done

if [[ "${PORT_FORWARD_READY}" != "true" ]]; then
  cat "${PORT_FORWARD_LOG}" >&2
  fail "Timed out while waiting for the Ingress controller port-forward."
fi

echo "Ingress controller available at 127.0.0.1:${LOCAL_INGRESS_PORT}"

info "17. Validating application HTTP response through Ingress..."

HTTP_STATUS="$(
  curl \
    --silent \
    --show-error \
    --output /dev/null \
    --write-out '%{http_code}' \
    --max-time "${HTTP_TIMEOUT}" \
    --header "Host: ${APP_HOST}" \
    "http://127.0.0.1:${LOCAL_INGRESS_PORT}/" \
    || true
)"

if [[ "${HTTP_STATUS}" != "${EXPECTED_HTTP_STATUS}" ]]; then
  echo "Application returned HTTP status: ${HTTP_STATUS:-unavailable}" >&2

  echo
  echo "Port-forward output:" >&2
  cat "${PORT_FORWARD_LOG}" >&2 || true

  echo
  echo "Pod status:" >&2
  kubectl get pods \
    --namespace "${NAMESPACE}" \
    --output=wide \
    || true

  echo
  echo "Ingress details:" >&2
  kubectl describe ingress "${JAVA_INGRESS}" \
    --namespace "${NAMESPACE}" \
    || true

  echo
  echo "Application logs:" >&2
  kubectl logs \
    "deployment/${JAVA_DEPLOYMENT}" \
    --namespace "${NAMESPACE}" \
    --all-pods=true \
    --tail=100 \
    || true

  fail "Application did not return HTTP ${EXPECTED_HTTP_STATUS}."
fi

echo
echo "========================================"
echo "Deployment validation successful"
echo "========================================"
echo "Namespace:           ${NAMESPACE}"
echo "Kube context:        ${CURRENT_CONTEXT}"
echo "Application host:    ${APP_HOST}"
echo "Validation endpoint: http://127.0.0.1:${LOCAL_INGRESS_PORT}"
echo "HTTP status:         ${HTTP_STATUS}"
echo "Java replicas:       ${READY_REPLICAS}/${EXPECTED_JAVA_REPLICAS}"
echo "MySQL primary:       ${EXPECTED_MYSQL_PRIMARY_REPLICAS}/${EXPECTED_MYSQL_PRIMARY_REPLICAS}"
echo "MySQL secondary:     ${EXPECTED_MYSQL_SECONDARY_REPLICAS}/${EXPECTED_MYSQL_SECONDARY_REPLICAS}"

