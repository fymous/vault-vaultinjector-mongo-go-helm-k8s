#!/bin/bash

# Test script to verify the Golang API is working without MongoDB

echo "Testing Golang API endpoints..."

# Get the service IP
GOLANG_SERVICE=$(kubectl get svc golang-app -n mongo-vault-operator -o jsonpath='{.spec.clusterIP}')
echo "Golang service IP: $GOLANG_SERVICE"

# Test health endpoint first
echo "Testing health endpoint..."
kubectl run curl-test --image=curlimages/curl --rm -it --restart=Never -n mongo-vault-operator -- \
  curl -s http://$GOLANG_SERVICE:8080/health

echo "Done!"
