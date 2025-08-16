#!/bin/bash

# Configure Vault with Kubernetes auth and MongoDB secrets

set -e

VAULT_POD=$(kubectl get pods -n mongo-vault-operator -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
NAMESPACE="mongo-vault-operator"
SERVICE_ACCOUNT="golang-app"

echo "Configuring Vault..."

# Execute commands inside Vault pod
echo "Enabling Kubernetes auth method..."
kubectl exec -n $NAMESPACE $VAULT_POD -- vault auth enable kubernetes || echo "Kubernetes auth already enabled"

# Configure Kubernetes auth method
kubectl exec -n $NAMESPACE $VAULT_POD -- vault write auth/kubernetes/config \
    token_reviewer_jwt="$(kubectl exec -n $NAMESPACE $VAULT_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert="$(kubectl exec -n $NAMESPACE $VAULT_POD -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"

# Enable KV secrets engine
echo "Enabling KV secrets engine..."
kubectl exec -n $NAMESPACE $VAULT_POD -- vault secrets enable -path=secrets kv-v2 || echo "KV secrets engine already enabled"

# Create a policy for the golang-app
kubectl exec -n $NAMESPACE $VAULT_POD -- sh -c 'echo "path \"secrets/data/mongo\" {
  capabilities = [\"read\"]
}" | vault policy write golang-app-policy -'

# Create a role for the golang-app service account
kubectl exec -n $NAMESPACE $VAULT_POD -- vault write auth/kubernetes/role/golang-app \
    bound_service_account_names=$SERVICE_ACCOUNT \
    bound_service_account_namespaces=$NAMESPACE \
    policies=golang-app-policy \
    ttl=24h

# Get MongoDB root password from secret
MONGO_ROOT_PASSWORD=$(kubectl get secret mongodb -n $NAMESPACE -o jsonpath='{.data.mongodb-root-password}' | base64 -d)

# Store MongoDB credentials in Vault
kubectl exec -n $NAMESPACE $VAULT_POD -- vault kv put secrets/mongo \
    username=root \
    password="$MONGO_ROOT_PASSWORD"

echo "Vault configuration completed!"
echo "MongoDB credentials stored with username: root"
echo "Role 'golang-app' created for service account '$SERVICE_ACCOUNT'"
