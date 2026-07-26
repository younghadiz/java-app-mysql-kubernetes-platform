#!/usr/bin/env bash

set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-java-mysql}"
LOCAL_PORT="${LOCAL_PORT:-8081}"
SERVICE_PORT="${SERVICE_PORT:-80}"

echo "Checking phpMyAdmin service..."

kubectl get service phpmyadmin \
    --namespace "${NAMESPACE}" >/dev/null

echo
echo "========================================="
echo "Starting phpMyAdmin port-forward..."
echo "Namespace : ${NAMESPACE}"
echo "Service   : phpmyadmin"
echo "URL       : http://127.0.0.1:${LOCAL_PORT}"
echo "========================================="
echo

kubectl port-forward \
    --namespace "${NAMESPACE}" \
    service/phpmyadmin \
    "${LOCAL_PORT}:${SERVICE_PORT}" \
    --address=127.0.0.1