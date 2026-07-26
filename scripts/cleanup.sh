#!/usr/bin/env bash

set -Eeuo pipefail

PROFILE="${MINIKUBE_PROFILE:-java-mysql-platform}"
NAMESPACE="${NAMESPACE:-java-mysql}"

JAVA_RELEASE="${JAVA_RELEASE:-java-app}"
MYSQL_RELEASE="${MYSQL_RELEASE:-mysql}"

EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-${PROFILE}}"

fail() {
  echo
  echo "CLEANUP FAILED: $1" >&2
  exit 1
}

info() {
  echo
  echo "$1"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

minikube_profile_exists() {
  minikube profile list \
    --output=json \
    2>/dev/null \
    | grep -q "\"Name\":\"${PROFILE}\""
}

helm_release_exists() {
  local release_name="$1"

  helm status "${release_name}" \
    --namespace "${NAMESPACE}" \
    >/dev/null 2>&1
}

cleanup_release() {
  local release_name="$1"

  if helm_release_exists "${release_name}"; then
    echo "Uninstalling Helm release: ${release_name}"

    helm uninstall "${release_name}" \
      --namespace "${NAMESPACE}" \
      --wait \
      --timeout 5m
  else
    echo "Helm release ${release_name} not found. Skipping."
  fi
}

info "1. Validating required command-line tools..."

for command in minikube kubectl helm grep; do
  command_exists "${command}" \
    || fail "Required command not found: ${command}"
done

echo "Required tools are installed."

info "2. Reviewing cleanup target..."

echo "Minikube profile: ${PROFILE}"
echo "Expected context:  ${EXPECTED_CONTEXT}"
echo "Namespace:         ${NAMESPACE}"
echo "Helm releases:"
echo "  - ${JAVA_RELEASE}"
echo "  - ${MYSQL_RELEASE}"

echo
echo "WARNING:"
echo "This operation will permanently remove:"
echo "  - the Java application Helm release"
echo "  - the MySQL Helm release"
echo "  - the ${NAMESPACE} namespace"
echo "  - all PVCs and local MySQL data in that namespace"
echo "  - the ${PROFILE} Minikube cluster"

echo
read -r -p "Type DELETE to continue: " CONFIRMATION

if [[ "${CONFIRMATION}" != "DELETE" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

info "3. Validating Minikube profile..."

if ! minikube_profile_exists; then
  echo "Minikube profile ${PROFILE} does not exist."
  echo "There is no local cluster to remove."
  exit 0
fi

echo "Minikube profile ${PROFILE} exists."

info "4. Switching to the project Minikube profile..."

minikube profile "${PROFILE}" >/dev/null

CURRENT_CONTEXT="$(
  kubectl config current-context 2>/dev/null || true
)"

if [[ -z "${CURRENT_CONTEXT}" ]]; then
  fail "No active Kubernetes context is configured."
fi

echo "Current context: ${CURRENT_CONTEXT}"

if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  fail "Refusing cleanup because the current context is ${CURRENT_CONTEXT}, expected ${EXPECTED_CONTEXT}."
fi

info "5. Validating cluster connectivity..."

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "The Kubernetes API is not currently reachable."
  echo "The Helm and namespace cleanup steps will be skipped."
  echo "The Minikube profile will still be deleted."

  minikube delete --profile="${PROFILE}"

  echo
  echo "Local environment removed."
  exit 0
fi

echo "Kubernetes API is reachable."

info "6. Checking namespace..."

if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} does not exist."
  echo "Skipping Helm release and namespace cleanup."
else
  echo "Namespace ${NAMESPACE} exists."

  info "7. Removing Java application Helm release..."

  cleanup_release "${JAVA_RELEASE}"

  info "8. Removing MySQL Helm release..."

  cleanup_release "${MYSQL_RELEASE}"

  info "9. Removing project namespace..."

  kubectl delete namespace "${NAMESPACE}" \
    --ignore-not-found=true \
    --wait=true \
    --timeout=5m

  echo "Namespace ${NAMESPACE} removed."
fi

info "10. Removing Minikube cluster..."

minikube delete --profile="${PROFILE}"

echo
echo "========================================"
echo "Local environment removed successfully"
echo "========================================"
echo "Minikube profile: ${PROFILE}"
echo "Namespace:        ${NAMESPACE}"
echo "Java release:     ${JAVA_RELEASE}"
echo "MySQL release:    ${MYSQL_RELEASE}" 