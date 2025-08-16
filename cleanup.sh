#!/bin/bash

# Cleanup script to remove all deployed services
set -e

NAMESPACE="mongo-vault-operator"

echo "Cleaning up all services..."

# Uninstall Helm releases
echo "Uninstalling Helm releases..."
helm uninstall golang-app -n "$NAMESPACE" || true
helm uninstall vault -n "$NAMESPACE" || true
helm uninstall mongodb -n "$NAMESPACE" || true

# Delete namespace
echo "Deleting namespace..."
kubectl delete namespace "$NAMESPACE" || true

echo "Cleanup completed!"
