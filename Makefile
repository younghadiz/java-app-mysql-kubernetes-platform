SHELL := /bin/bash

PROFILE ?= java-mysql-platform
NAMESPACE ?= java-mysql
APP_HOST ?= my-java-app.com

HELMFILE ?= helmfile
KUBECTL ?= kubectl
MINIKUBE ?= minikube

.PHONY: \
	help \
	cluster \
	secrets \
	diff \
	deploy \
	mysql \
	app \
	phpmyadmin \
	ingress \
	status \
	validate \
	port-forward \
	clean

help:
	@echo "Available targets:"
	@echo ""
	@echo "  make cluster       Start the Minikube cluster and enable ingress"
	@echo "  make secrets       Create local Kubernetes secrets"
	@echo "  make diff          Preview all Helmfile deployment changes"
	@echo "  make deploy        Deploy all Helmfile-managed releases"
	@echo "  make mysql         Deploy or update only MySQL"
	@echo "  make app           Deploy or update only the Java application"
	@echo "  make phpmyadmin    Apply the phpMyAdmin Kubernetes resources"
	@echo "  make ingress       Apply the Java application ingress resource"
	@echo "  make status        Display cluster and application status"
	@echo "  make validate      Validate the complete deployment"
	@echo "  make port-forward  Access phpMyAdmin locally"
	@echo "  make clean         Remove the local environment"
	@echo ""
	@echo "Optional overrides:"
	@echo "  PROFILE=<name>"
	@echo "  NAMESPACE=<namespace>"
	@echo "  APP_HOST=<hostname>"

cluster:
	MINIKUBE_PROFILE="$(PROFILE)" \
	NAMESPACE="$(NAMESPACE)" \
	./scripts/bootstrap-local-cluster.sh

secrets:
	NAMESPACE="$(NAMESPACE)" \
	./scripts/create-local-secrets.sh

diff:
	$(HELMFILE) diff

deploy:
	$(HELMFILE) apply

mysql:
	$(HELMFILE) \
		--selector name=mysql \
		apply

app:
	$(HELMFILE) \
		--selector name=java-app \
		apply

phpmyadmin:
	$(KUBECTL) apply \
		--namespace "$(NAMESPACE)" \
		-f kubernetes/phpmyadmin/deployment.yaml \
		-f kubernetes/phpmyadmin/service.yaml

ingress:
	$(KUBECTL) apply \
		--namespace "$(NAMESPACE)" \
		-f kubernetes/ingress/ingress.yaml

status:
	@echo
	@echo "Minikube profile:"
	@$(MINIKUBE) status --profile "$(PROFILE)" || true
	@echo
	@echo "Helm releases:"
	@helm list --namespace "$(NAMESPACE)" || true
	@echo
	@echo "Kubernetes resources:"
	@$(KUBECTL) get \
		deployments,statefulsets,pods,services,ingresses,pvc \
		--namespace "$(NAMESPACE)" \
		--output=wide || true

validate:
	NAMESPACE="$(NAMESPACE)" \
	APP_HOST="$(APP_HOST)" \
	./scripts/validate-deployment.sh

port-forward:
	NAMESPACE="$(NAMESPACE)" \
	./scripts/port-forward-phpmyadmin.sh

clean:
	MINIKUBE_PROFILE="$(PROFILE)" \
	NAMESPACE="$(NAMESPACE)" \
	./scripts/cleanup.sh

