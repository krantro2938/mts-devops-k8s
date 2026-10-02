# Convenience wrapper. Every target is a thin call into scripts/ (see README).
SHELL := /bin/bash
.DEFAULT_GOAL := help

export KUBECONFIG ?= $(HOME)/.kube/config

.PHONY: help up cluster deploy test traffic creds status urls lint dashboard reset

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

up: cluster deploy test ## Everything: kubeadm cluster + all components + smoke tests

cluster: ## Prepare Ubuntu 24.04 and create the kubeadm cluster (uses sudo)
	sudo -E ./scripts/bootstrap-node.sh

deploy: ## Install / update all in-cluster components (idempotent)
	./scripts/deploy.sh

test: ## Run end-to-end smoke tests
	./scripts/smoke-test.sh

traffic: ## Generate demo traffic for 60s (dashboards)
	./scripts/generate-traffic.sh 60 5

creds: ## Print the admin credentials (Grafana, Prometheus, Alertmanager, VictoriaLogs)
	@echo "user:     $$(kubectl -n monitoring get secret ops-credentials -o jsonpath='{.data.username}' | base64 -d)"
	@echo "password: $$(kubectl -n monitoring get secret ops-credentials -o jsonpath='{.data.password}' | base64 -d)"

status: ## Show the state of nodes, Gateway API resources and workloads
	kubectl get nodes -o wide
	kubectl get gatewayclass,gateway -A
	kubectl get httproute -A
	kubectl get pods -A -o wide

urls: ## Print /etc/hosts line and URLs
	@ip=$$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'); \
	echo "$$ip hello.demo.local v2.demo.local canary.demo.local secure.demo.local grafana.demo.local prometheus.demo.local alertmanager.demo.local logs.demo.local"; \
	echo "http://$$ip:30080/  http://grafana.demo.local:30080  http://prometheus.demo.local:30080  http://logs.demo.local:30080"

lint: ## Static checks (shellcheck, yamllint, helm lint, kubeconform) - same as CI
	./tests/lint.sh

dashboard: ## Regenerate the Grafana dashboard JSON from tests/gen-dashboard.py
	python3 tests/gen-dashboard.py

reset: ## DESTRUCTIVE: kubeadm reset of this node
	sudo ./scripts/reset-node.sh
