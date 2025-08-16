#!/bin/bash

# Deployment script for all services
set -e

echo "Starting deployment of all services..."

# Single namespace for all services
NAMESPACE="mongo-vault-operator"



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


# Create namespace first
kubectl create namespace "$NAMESPACE" || echo "Namespace already exists"

# Deploy Vault 
echo "Deploying Vault..."
helm dependency update helm/vault
helm upgrade --install vault helm/vault --namespace "$NAMESPACE"
echo "Vault deployment initiated!"

# Wait for Vault to be ready
echo "Waiting for Vault to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s -n "$NAMESPACE"

# Configure Vault automatically
echo "Configuring Vault..."
kubectl apply -f vault-config-job.yaml
kubectl wait --for=condition=complete job/vault-config --timeout=300s -n "$NAMESPACE"
echo "Vault configuration completed!"

# Deploy MongoDB (after Helm creates namespace)
echo "MongoDB deployment initiated!"
echo "Deploying MongoDB (ARM64 custom manifest)..."
kubectl apply -f k8s-mongo-arm64.yaml
echo "MongoDB deployment initiated!"

# Deploy Golang application
echo "Deploying Golang application..."
helm template golang-app helm/golang-app --namespace "$NAMESPACE" | kubectl apply -f -
echo "All services deployment completed!"
echo ""
echo "Check pod status:"
echo "kubectl get pods -n $NAMESPACE"
echo ""
echo "To access the services:"
echo "Vault UI: kubectl port-forward svc/vault-ui -n $NAMESPACE 8200:8200"
echo "Golang App: kubectl port-forward svc/golang-app -n $NAMESPACE 8080:8080"
