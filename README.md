# Vault-Kubernetes Integration Project

This project demonstrates a complete microservices setup with HashiCorp Vault for secret management, MongoDB for data persistence, and a Golang REST API application. All services are deployed using Helm charts in separate Kubernetes namespaces.

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Golang App    │    │      Vault      │    │    MongoDB      │
│  (golang-app)   │◄──►│    (vault)      │    │   (mongodb)     │
│                 │    │                 │    │                 │
│ - REST API      │    │ - Secret Store  │    │ - Database      │
│ - Port 8080     │    │ - Auth Provider │    │ - Port 27017    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       │
         └───────────────────────┼───────────────────────┘
                                 │
                    ┌─────────────────┐
                    │ Vault Injector  │
                    │   (built-in)    │
                    │                 │
                    │ - Secret Inject │
                    │ - Auto Mount    │
                    └─────────────────┘
```

## Components

### 1. Golang Application (`golang-app` namespace)
- **Purpose**: REST API server with MongoDB integration
- **Features**:
  - POST `/api/users` - Create new users
  - GET `/api/users` - Retrieve all users
  - GET `/health` - Health check endpoint
- **Vault Integration**: Uses Vault Agent Injector to get MongoDB credentials
- **Docker**: Multi-stage build with Alpine Linux base

### 2. MongoDB (`mongodb` namespace)
- **Purpose**: Data persistence layer
- **Features**:
  - Bitnami MongoDB Helm chart
  - Authentication enabled
  - Auto-generated passwords
  - Persistent storage
- **Credentials**: Root and application user passwords stored in Vault

### 3. HashiCorp Vault (`vault` namespace)
- **Purpose**: Secret management and authentication
- **Features**:
  - Development mode (for demo purposes)
  - Kubernetes authentication method
  - KV secrets engine
  - Policy-based access control
- **Vault Injector**: Automatically injects secrets into pods

## Project Structure

```
├── helm/                          # Helm charts directory
│   ├── golang-app/               # Golang application chart
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       ├── serviceaccount.yaml
│   │       ├── namespace.yaml
│   │       └── _helpers.tpl
│   ├── mongodb/                  # MongoDB chart wrapper
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       └── namespace.yaml
│   └── vault/                    # Vault chart wrapper
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── configure-vault.sh
│       └── templates/
│           └── namespace.yaml
├── go-app/                       # Golang application source
│   ├── main.go
│   ├── go.mod
│   ├── Dockerfile
│   └── README.md
├── deploy.sh                     # Deployment script
├── cleanup.sh                    # Cleanup script
└── README.md
```

## Prerequisites

- Kubernetes cluster (minikube, kind, or cloud provider)
- Helm 3.x installed
- kubectl configured
- Docker (for building images)
- Vault CLI (optional, for manual operations)

## Quick Start

### 1. Deploy All Services

```bash
# Make scripts executable
chmod +x deploy.sh cleanup.sh

# Deploy all services
./deploy.sh
```

### 2. Access Services

```bash
# Access Golang API
kubectl port-forward svc/golang-app -n golang-app 8080:8080

# Access Vault UI
kubectl port-forward svc/vault-ui -n vault 8200:8200

# Access MongoDB (if needed)
kubectl port-forward svc/mongodb -n mongodb 27017:27017
```

### 3. Test the API

```bash
# Health check
curl http://localhost:8080/health

# Create a user
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "email": "john@example.com", "age": 30}'

# Get all users
curl http://localhost:8080/api/users
```

## Vault Integration Details

### Secret Storage
- **Path**: `secrets/mongo`
- **Keys**: `username`, `password`
- **Values**: MongoDB application user credentials

### Authentication
- **Method**: Kubernetes authentication
- **Role**: `golang-app`
- **Policy**: `golang-app-policy`
- **Bound to**: ServiceAccount `golang-app` in namespace `golang-app`

### Injection Configuration
The Golang application uses Vault Agent Injector with these annotations:
```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "golang-app"
vault.hashicorp.com/agent-inject-secret-mongo: "secrets/mongo"
vault.hashicorp.com/agent-inject-template-mongo: |
  {{- with secret "secrets/mongo" -}}
  export MONGO_USER="{{ .Data.data.username }}"
  export MONGO_PASSWORD="{{ .Data.data.password }}"
  {{- end -}}
```

## Security Features

1. **Namespace Isolation**: Each service runs in its own namespace
2. **RBAC**: Service accounts with minimal required permissions
3. **Secret Management**: All sensitive data stored in Vault
4. **Authentication**: MongoDB requires authentication
5. **Network Policies**: Can be added for additional network isolation

## Future Extensions (Operator Pattern)

This setup provides the foundation for an operator-based deployment where:

1. **Custom Resource Definitions (CRDs)**: Define application specifications
2. **Operator Controller**: Watches for CRD changes and manages Helm deployments
3. **Automated Lifecycle**: Handle updates, scaling, and monitoring
4. **GitOps Integration**: Sync with Git repositories for configuration

## Monitoring and Observability

Future enhancements can include:
- Prometheus metrics collection
- Grafana dashboards
- Distributed tracing with Jaeger
- Centralized logging with ELK stack

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -A
```

### Check Vault Logs
```bash
kubectl logs -l app.kubernetes.io/name=vault -n vault
```

### Check Golang App Logs
```bash
kubectl logs -l app.kubernetes.io/name=golang-app -n golang-app
```

### Check MongoDB Logs
```bash
kubectl logs -l app.kubernetes.io/name=mongodb -n mongodb
```

### Manual Vault Access
```bash
kubectl port-forward svc/vault -n vault 8200:8200
export VAULT_ADDR="http://localhost:8200"
export VAULT_TOKEN="root-token"
vault status
```

## Cleanup

To remove all deployed services:

```bash
./cleanup.sh
```

This will:
- Uninstall all Helm releases
- Delete all created namespaces
- Clean up associated resources
