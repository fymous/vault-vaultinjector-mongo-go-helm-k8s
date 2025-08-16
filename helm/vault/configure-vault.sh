#!/bin/bash

# Vault configuration script to set up secrets and policies

# Wait for Vault to be ready
echo "Waiting for Vault to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s

# Port forward to access Vault
echo "Setting up port forward to Vault..."
kubectl port-forward svc/vault -n vault 8200:8200 &
PORTFORWARD_PID=$!

# Wait for port forward to be established
sleep 5

# Set Vault address and token
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="root-token"

# Enable KV secrets engine
echo "Enabling KV secrets engine..."
vault secrets enable -path=secrets kv-v2

# Create a policy for the golang app
echo "Creating policy for golang app..."
vault policy write golang-app-policy - <<EOF
path "secrets/data/mongo" {
  capabilities = ["read"]
}
EOF

# Enable Kubernetes auth method
echo "Enabling Kubernetes auth method..."
vault auth enable kubernetes

# Configure Kubernetes auth
echo "Configuring Kubernetes auth..."
vault write auth/kubernetes/config \
    token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Create a role for the golang app
echo "Creating role for golang app..."
vault write auth/kubernetes/role/golang-app \
    bound_service_account_names=golang-app \
    bound_service_account_namespaces=golang-app \
    policies=golang-app-policy \
    ttl=24h

# Store MongoDB credentials (these will be updated with actual values after MongoDB deployment)
echo "Storing MongoDB credentials..."
vault kv put secrets/mongo username="appuser" password="changeme123"

# Clean up port forward
kill $PORTFORWARD_PID

echo "Vault configuration completed!"
