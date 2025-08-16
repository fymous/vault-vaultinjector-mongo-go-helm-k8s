# Vault Integration Guide: Complete Step-by-Step Implementation

## Overview
This guide documents the complete implementation of HashiCorp Vault integration with MongoDB and a Go application in Kubernetes, using Helm charts and automated deployment scripts.

## Architecture
- **HashiCorp Vault**: Secret management and injection
- **Vault Agent Injector**: Automatic secret injection into pods
- **MongoDB**: Database with ARM64 compatibility
- **Go Application**: REST API that retrieves MongoDB credentials from Vault
- **Single Namespace**: All services deployed in `mongo-vault-operator`

---

## What We Built: Step-by-Step Journey

### 1. Initial Setup and Requirements
**Goal**: Deploy 4 services (Vault, Vault Injector, MongoDB, Go App) using Helm in Kubernetes

**Initial Challenges**:
- ARM64 compatibility for MongoDB on Apple Silicon
- Vault manual configuration complexity
- Namespace ownership conflicts with Helm
- Secret injection configuration

### 2. Vault Deployment and Configuration

#### 2.1 Vault Helm Chart Setup
Created `helm/vault/Chart.yaml`:
```yaml
apiVersion: v2
name: vault
description: HashiCorp Vault Helm chart
type: application
version: 0.1.0
appVersion: "1.15.2"

dependencies:
  - name: vault
    version: "0.28.1"
    repository: "https://helm.releases.hashicorp.com"
```

#### 2.2 Vault Configuration
Created `helm/vault/values.yaml`:
```yaml
vault:
  server:
    dev:
      enabled: true
      devRootToken: "dev-only-token"
    
  injector:
    enabled: true
    
  ui:
    enabled: true
```

**Key Points**:
- Dev mode for simplicity (not for production)
- Vault Injector enabled for automatic secret injection
- UI enabled for debugging

### 3. MongoDB ARM64 Compatibility Solution

#### 3.1 Problem
Bitnami MongoDB chart didn't work on ARM64 (Apple Silicon)

#### 3.2 Solution
Created custom ARM64 MongoDB manifest `k8s-mongo-arm64.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongo-arm64
  namespace: mongo-vault-operator
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongo-arm64
  template:
    metadata:
      labels:
        app: mongo-arm64
    spec:
      containers:
      - name: mongo
        image: mongo:7.0
        ports:
        - containerPort: 27017
        env:
        - name: MONGO_INITDB_ROOT_USERNAME
          value: "root"
        - name: MONGO_INITDB_ROOT_PASSWORD
          value: "example"
---
apiVersion: v1
kind: Service
metadata:
  name: mongo-arm64
  namespace: mongo-vault-operator
spec:
  selector:
    app: mongo-arm64
  ports:
  - port: 27017
    targetPort: 27017
```

### 4. Automated Vault Configuration

#### 4.1 Problem
Manual Vault configuration steps were complex and not operator-friendly

#### 4.2 Solution
Created `vault-config-job.yaml` - Kubernetes Job for automated Vault setup:
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-config
  namespace: mongo-vault-operator
spec:
  template:
    spec:
      serviceAccountName: vault-config
      containers:
      - name: vault-config
        image: hashicorp/vault:1.15.2
        env:
        - name: VAULT_ADDR
          value: "http://vault.mongo-vault-operator.svc.cluster.local:8200"
        - name: VAULT_TOKEN
          value: "dev-only-token"
        command:
        - /bin/sh
        - -c
        - |
          # Wait for Vault to be ready
          until vault status; do
            echo "Waiting for Vault..."
            sleep 5
          done
          
          # Enable Kubernetes auth
          vault auth enable kubernetes || echo "Kubernetes auth already enabled"
          
          # Configure Kubernetes auth
          vault write auth/kubernetes/config \
            token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
            kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT" \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
          
          # Create MongoDB secret
          vault kv put secret/mongo username=root password=example
          
          # Create policy
          vault policy write mongo-policy - <<EOF
          path "secret/data/mongo" {
            capabilities = ["read"]
          }
          EOF
          
          # Create role
          vault write auth/kubernetes/role/mongo-role \
            bound_service_account_names=golang-app \
            bound_service_account_namespaces=mongo-vault-operator \
            policies=mongo-policy \
            ttl=24h
      restartPolicy: OnFailure
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-config
  namespace: mongo-vault-operator
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vault-config
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: vault-config
  namespace: mongo-vault-operator
```

### 5. Go Application with Vault Integration

#### 5.1 Go Application Structure
Created `go-app/main.go` with Vault secret injection:
```go
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "io/ioutil"
    "log"
    "net/http"
    "os"
    "time"
    
    "github.com/gorilla/mux"
    "go.mongodb.org/mongo-driver/bson"
    "go.mongodb.org/mongo-driver/bson/primitive"
    "go.mongodb.org/mongo-driver/mongo"
    "go.mongodb.org/mongo-driver/mongo/options"
)

type User struct {
    ID    primitive.ObjectID `json:"id" bson:"_id,omitempty"`
    Name  string             `json:"name" bson:"name"`
    Email string             `json:"email" bson:"email"`
    Age   int                `json:"age" bson:"age"`
}

type App struct {
    client *mongo.Client
    db     *mongo.Database
}

func readVaultSecret(path string) (string, error) {
    data, err := ioutil.ReadFile(path)
    if err != nil {
        return "", err
    }
    return string(data), nil
}

func (a *App) connectToMongoDB() error {
    // Read credentials from Vault-injected files
    username, err := readVaultSecret("/vault/secrets/mongo_username")
    if err != nil {
        return fmt.Errorf("failed to read username from Vault: %v", err)
    }
    
    password, err := readVaultSecret("/vault/secrets/mongo_password")
    if err != nil {
        return fmt.Errorf("failed to read password from Vault: %v", err)
    }
    
    log.Printf("Successfully read credentials from Vault - User: %s, Password: ***hidden***", username)
    
    // MongoDB connection string with proper service name and authSource
    mongoURI := fmt.Sprintf("mongodb://%s:%s@mongo-arm64.mongo-vault-operator.svc.cluster.local:27017/appdb?authSource=admin", username, password)
    
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    
    client, err := mongo.Connect(ctx, options.Client().ApplyURI(mongoURI))
    if err != nil {
        return fmt.Errorf("failed to connect to MongoDB: %v", err)
    }
    
    // Check the connection
    err = client.Ping(ctx, nil)
    if err != nil {
        return fmt.Errorf("failed to ping MongoDB: %v", err)
    }
    
    a.client = client
    a.db = client.Database("appdb")
    
    log.Println("Connected to MongoDB successfully!")
    return nil
}

func (a *App) createUser(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    
    var user User
    if err := json.NewDecoder(r.Body).Decode(&user); err != nil {
        http.Error(w, err.Error(), http.StatusBadRequest)
        return
    }
    
    user.ID = primitive.NewObjectID()
    
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    
    _, err := a.db.Collection("users").InsertOne(ctx, user)
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    
    json.NewEncoder(w).Encode(user)
}

func (a *App) getUsers(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    
    cursor, err := a.db.Collection("users").Find(ctx, bson.M{})
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    defer cursor.Close(ctx)
    
    var users []User
    if err = cursor.All(ctx, &users); err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    
    json.NewEncoder(w).Encode(users)
}

func (a *App) healthCheck(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    response := map[string]interface{}{
        "service":   "golang-app",
        "status":    "healthy",
        "timestamp": time.Now().UTC().Format(time.RFC3339),
    }
    json.NewEncoder(w).Encode(response)
}

func main() {
    app := &App{}
    
    // Connect to MongoDB
    if err := app.connectToMongoDB(); err != nil {
        log.Fatalf("Failed to connect to MongoDB: %v", err)
    }
    
    // Setup routes
    r := mux.NewRouter()
    r.HandleFunc("/api/users", app.createUser).Methods("POST")
    r.HandleFunc("/api/users", app.getUsers).Methods("GET")
    r.HandleFunc("/health", app.healthCheck).Methods("GET")
    
    log.Println("Server starting on port 8080")
    log.Fatal(http.ListenAndServe(":8080", r))
}
```

#### 5.2 Go Application Helm Chart
Created `helm/golang-app/templates/deployment.yaml` with Vault annotations:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.app.name }}
  namespace: {{ .Values.namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.app.name }}
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "mongo-role"
        vault.hashicorp.com/agent-inject-secret-mongo_username: "secret/data/mongo"
        vault.hashicorp.com/agent-inject-template-mongo_username: |
          {{ "{{" }}- with secret "secret/data/mongo" -{{ "}}" }}
          {{ "{{" }} .Data.data.username {{ "}}" }}
          {{ "{{" }}- end -{{ "}}" }}
        vault.hashicorp.com/agent-inject-secret-mongo_password: "secret/data/mongo"
        vault.hashicorp.com/agent-inject-template-mongo_password: |
          {{ "{{" }}- with secret "secret/data/mongo" -{{ "}}" }}
          {{ "{{" }} .Data.data.password {{ "}}" }}
          {{ "{{" }}- end -{{ "}}" }}
      labels:
        app: {{ .Values.app.name }}
    spec:
      serviceAccountName: {{ .Values.app.name }}
      containers:
      - name: {{ .Values.app.name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        ports:
        - containerPort: {{ .Values.service.targetPort }}
        imagePullPolicy: {{ .Values.image.pullPolicy }}
```

### 6. Deployment Script Automation

#### 6.1 Complete Deployment Script
Created `deploy.sh` for full automation:
```bash
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
```

---

## Commands Needed for Complete Deployment

### Prerequisites
```bash
# Ensure you have the following tools installed:
# - Docker
# - kubectl
# - helm
# - A running Kubernetes cluster (Docker Desktop, minikube, etc.)
```

### Single Command Deployment
```bash
# Run the deployment script
./deploy.sh
```

### Manual Step-by-Step Commands (if needed)
```bash
# 1. Add Helm repositories
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# 2. Build Go app
cd go-app
docker build -t golang-app:latest .
cd ..

# 3. Create namespace
kubectl create namespace mongo-vault-operator

# 4. Deploy Vault
helm dependency update helm/vault
helm upgrade --install vault helm/vault --namespace mongo-vault-operator

# 5. Wait for Vault
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s -n mongo-vault-operator

# 6. Configure Vault automatically
kubectl apply -f vault-config-job.yaml
kubectl wait --for=condition=complete job/vault-config --timeout=300s -n mongo-vault-operator

# 7. Deploy MongoDB
kubectl apply -f k8s-mongo-arm64.yaml

# 8. Deploy Go app
helm template golang-app helm/golang-app --namespace mongo-vault-operator | kubectl apply -f -

# 9. Check status
kubectl get pods -n mongo-vault-operator

# 10. Access services
kubectl port-forward svc/golang-app 8080:8080 -n mongo-vault-operator
kubectl port-forward svc/vault-ui 8200:8200 -n mongo-vault-operator
```

### Testing the Application
```bash
# Health check
curl http://localhost:8080/health

# Create a user
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "email": "john.doe@example.com"}'

# Get all users
curl http://localhost:8080/api/users
```

---

## How to Integrate Vault into Any Existing Application

### Step 1: Analyze Your Current Application
1. **Identify secrets** your app currently uses (database passwords, API keys, etc.)
2. **Locate where secrets are stored** (environment variables, config files, etc.)
3. **Note the application language** and framework

### Step 2: Prepare Vault Infrastructure
```bash
# 1. Copy these files to your project:
# - vault-config-job.yaml
# - helm/vault/ (directory)

# 2. Modify vault-config-job.yaml for your secrets:
vault kv put secret/your-app \
  database_password=your-db-password \
  api_key=your-api-key \
  other_secret=your-other-secret

# 3. Update the policy name and paths in vault-config-job.yaml
vault policy write your-app-policy - <<EOF
path "secret/data/your-app" {
  capabilities = ["read"]
}
EOF

# 4. Update the role configuration
vault write auth/kubernetes/role/your-app-role \
  bound_service_account_names=your-app-service-account \
  bound_service_account_namespaces=your-namespace \
  policies=your-app-policy \
  ttl=24h
```

### Step 3: Modify Your Application Code

#### For Go Applications:
```go
// Add this function to read Vault secrets
func readVaultSecret(path string) (string, error) {
    data, err := ioutil.ReadFile(path)
    if err != nil {
        return "", err
    }
    return string(data), nil
}

// Replace hard-coded secrets with Vault reads
func initializeApp() error {
    dbPassword, err := readVaultSecret("/vault/secrets/database_password")
    if err != nil {
        return fmt.Errorf("failed to read database password: %v", err)
    }
    
    apiKey, err := readVaultSecret("/vault/secrets/api_key")
    if err != nil {
        return fmt.Errorf("failed to read API key: %v", err)
    }
    
    // Use the secrets in your application
    // ...
}
```

#### For Python Applications:
```python
def read_vault_secret(path):
    try:
        with open(path, 'r') as file:
            return file.read().strip()
    except Exception as e:
        raise Exception(f"Failed to read secret from {path}: {e}")

# Replace hard-coded secrets
database_password = read_vault_secret("/vault/secrets/database_password")
api_key = read_vault_secret("/vault/secrets/api_key")
```

#### For Node.js Applications:
```javascript
const fs = require('fs');

function readVaultSecret(path) {
    try {
        return fs.readFileSync(path, 'utf8').trim();
    } catch (error) {
        throw new Error(`Failed to read secret from ${path}: ${error.message}`);
    }
}

// Replace hard-coded secrets
const databasePassword = readVaultSecret('/vault/secrets/database_password');
const apiKey = readVaultSecret('/vault/secrets/api_key');
```

### Step 4: Update Kubernetes Manifests

#### Add Vault Annotations to Your Deployment:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-app
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "your-app-role"
        
        # For each secret, add these two annotations:
        vault.hashicorp.com/agent-inject-secret-database_password: "secret/data/your-app"
        vault.hashicorp.com/agent-inject-template-database_password: |
          {{- with secret "secret/data/your-app" -}}
          {{ .Data.data.database_password }}
          {{- end -}}
        
        vault.hashicorp.com/agent-inject-secret-api_key: "secret/data/your-app"
        vault.hashicorp.com/agent-inject-template-api_key: |
          {{- with secret "secret/data/your-app" -}}
          {{ .Data.data.api_key }}
          {{- end -}}
    spec:
      serviceAccountName: your-app  # Make sure this exists
      containers:
      - name: your-app
        image: your-app:latest
        # Remove environment variables with secrets
        # env:
        # - name: DATABASE_PASSWORD  # Remove these
        #   value: "hard-coded-password"
```

### Step 5: Create ServiceAccount and RBAC
```yaml
# Add to your Kubernetes manifests
apiVersion: v1
kind: ServiceAccount
metadata:
  name: your-app
  namespace: your-namespace
```

### Step 6: Update Your Deployment Script
```bash
# Add to your deployment script (before deploying your app):

# Deploy Vault if not already deployed
helm upgrade --install vault helm/vault --namespace your-namespace

# Wait for Vault
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault --timeout=300s -n your-namespace

# Configure Vault with your secrets
kubectl apply -f vault-config-job.yaml
kubectl wait --for=condition=complete job/vault-config --timeout=300s -n your-namespace

# Then deploy your application
kubectl apply -f your-app-manifests/
```

### Step 7: Test the Integration
```bash
# 1. Deploy everything
./your-deploy-script.sh

# 2. Check that your app pod has 2 containers (app + vault-agent)
kubectl get pods -n your-namespace

# 3. Check that secrets are injected
kubectl exec -it your-app-pod -c your-app -- ls -la /vault/secrets/

# 4. Check application logs
kubectl logs your-app-pod -c your-app

# 5. Test your application functionality
```

---

## Key Lessons Learned

### 1. **Namespace Ownership with Helm**
- **Problem**: Multiple Helm releases can't own the same namespace
- **Solution**: Use `helm template ... | kubectl apply -f -` for secondary deployments

### 2. **ARM64 Compatibility**
- **Problem**: Many Docker images don't support ARM64
- **Solution**: Use multi-arch images or create custom manifests

### 3. **Vault Agent Injection**
- **Key Point**: Secrets are written as files in `/vault/secrets/` directory
- **Template Format**: Use Vault's templating syntax for secret extraction

### 4. **Service Discovery**
- **Format**: `service-name.namespace.svc.cluster.local`
- **Example**: `mongo-arm64.mongo-vault-operator.svc.cluster.local`

### 5. **MongoDB Authentication**
- **Key Point**: Use `authSource=admin` for root user authentication
- **Connection String**: `mongodb://user:pass@host:port/database?authSource=admin`

---

## Security Considerations for Production

### 1. **Vault Configuration**
- Use proper TLS/SSL certificates
- Use Vault's unsealing process instead of dev mode
- Implement proper backup and disaster recovery
- Use least-privilege policies

### 2. **Kubernetes RBAC**
- Create specific service accounts for each application
- Limit permissions to minimum required
- Use namespaces for isolation

### 3. **Secret Rotation**
- Implement automatic secret rotation
- Set appropriate TTL values
- Monitor secret access and usage

### 4. **Network Security**
- Use network policies to restrict traffic
- Implement service mesh for additional security
- Use TLS for all inter-service communication

---

## Troubleshooting Common Issues

### 1. **Vault Agent Not Injecting Secrets**
```bash
# Check if Vault Injector is running
kubectl get pods -n your-namespace | grep vault-agent-injector

# Check pod annotations
kubectl describe pod your-app-pod

# Check vault-agent logs
kubectl logs your-app-pod -c vault-agent
```

### 2. **Application Can't Read Secrets**
```bash
# Check if secret files exist
kubectl exec -it your-app-pod -c your-app -- ls -la /vault/secrets/

# Check file permissions
kubectl exec -it your-app-pod -c your-app -- cat /vault/secrets/your-secret
```

### 3. **MongoDB Connection Issues**
```bash
# Check MongoDB pod status
kubectl get pods | grep mongo

# Check MongoDB logs
kubectl logs mongo-pod

# Test connection from app pod
kubectl exec -it your-app-pod -c your-app -- nc -zv mongo-service 27017
```

---

## Files Created/Modified Summary

### New Files:
1. `vault-config-job.yaml` - Automated Vault configuration
2. `k8s-mongo-arm64.yaml` - ARM64 MongoDB deployment
3. `helm/vault/Chart.yaml` - Vault Helm chart
4. `helm/vault/values.yaml` - Vault configuration
5. `helm/golang-app/` - Complete Helm chart for Go app
6. `go-app/main.go` - Go application with Vault integration
7. `go-app/Dockerfile` - Docker build configuration
8. `deploy.sh` - Complete deployment automation

### Modified Concepts:
- Moved from manual Vault configuration to automated Jobs
- Switched from Bitnami MongoDB to custom ARM64 manifest
- Changed from `helm install` to `helm template | kubectl apply` for namespace ownership
- Integrated Vault Agent Injector for automatic secret management

This documentation provides a complete blueprint for implementing Vault integration in any Kubernetes application, with all the lessons learned and best practices from our implementation.
