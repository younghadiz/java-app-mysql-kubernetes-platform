#!/usr/bin/env bash

set -Eeuo pipefail

PROFILE="${MINIKUBE_PROFILE:-java-mysql-platform}"
CPUS="${MINIKUBE_CPUS:-4}"
MEMORY="${MINIKUBE_MEMORY:-6144}"
DISK_SIZE="${MINIKUBE_DISK_SIZE:-30g}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-stable}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker Desktop is not running."
  exit 1
fi

for command_name in minikube kubectl helm; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "ERROR: ${command_name} is not installed."
    exit 1
  fi
done

echo "Starting Minikube profile: ${PROFILE}"

minikube start \
  --profile="${PROFILE}" \
  --driver=docker \
  --cpus="${CPUS}" \
  --memory="${MEMORY}" \
  --disk-size="${DISK_SIZE}" \
  --kubernetes-version="${KUBERNETES_VERSION}"

kubectl config use-context "${PROFILE}"

echo "Enabling ingress addon..."
minikube addons enable ingress --profile="${PROFILE}"

echo "Applying project namespace..."
kubectl apply -f kubernetes/base/namespace.yaml

echo "Waiting for Kubernetes nodes..."
kubectl wait \
  --for=condition=Ready \
  node \
  --all \
  --timeout=180s

echo "Waiting for ingress controller..."
kubectl wait \
  --namespace ingress-nginx \
  --for=condition=Available \
  deployment/ingress-nginx-controller \
  --timeout=300s

echo
echo "Cluster status:"
kubectl cluster-info
kubectl get nodes -o wide
kubectl get namespaces

echo
echo "Minikube IP:"
minikube ip --profile="${PROFILE}"