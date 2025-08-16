#!/bin/bash

# Deployment script for all services
set -e

echo "Starting deployment of all services..."

# Single namespace for all services
NAMESPACE="mongo-vault-operator"

# Function to check if namespace exists
check_namespace() {
    local ns=$1
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Namespace $ns already exists"
    else
        echo "Creating namespace $ns"
        kubectl create namespace "$ns"
    fi
}

# Create the main namespace
check_namespace "$NAMESPACE"

echo "Deployment script is working!"

# Add Helm repositories
echo "Adding Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Build Golang app Docker image
echo "Building Golang application Docker image..."
cd go-app
docker build -t golang-app:latest .
cd ..

# Deploy MongoDB
echo "Deploying MongoDB..."
helm dependency update helm/mongodb
helm upgrade --install mongodb helm/mongodb --namespace "$NAMESPACE"

echo "MongoDB deployment initiated!"

# Deploy Vault
echo "Deploying Vault..."
helm dependency update helm/vault
helm upgrade --install vault helm/vault --namespace "$NAMESPACE"

echo "Vault deployment initiated!"

# Deploy Golang application
echo "Deploying Golang application..."
helm upgrade --install golang-app helm/golang-app --namespace "$NAMESPACE"

echo "All services deployment completed!"
echo ""
echo "Check pod status:"
echo "kubectl get pods -n $NAMESPACE"
echo ""
echo "To access the services:"
echo "Vault UI: kubectl port-forward svc/vault-ui -n $NAMESPACE 8200:8200"
echo "Golang App: kubectl port-forward svc/golang-app -n $NAMESPACE 8080:8080"
