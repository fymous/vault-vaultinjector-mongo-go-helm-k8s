# Golang App

This is a simple REST API built with Go that connects to MongoDB and provides user management functionality.

## Features

- **POST /api/users**: Create a new user
- **GET /api/users**: Retrieve all users
- **GET /health**: Health check endpoint

## MongoDB Integration

The application connects to MongoDB using credentials injected by Vault:
- Uses environment variables `MONGO_USER` and `MONGO_PASSWORD`
- Connects to MongoDB service at `mongodb.mongodb.svc.cluster.local:27017`
- Uses database named `appdb` and collection `users`

## Vault Integration

The application is configured to work with HashiCorp Vault for secret management:
- Vault Agent Injector injects MongoDB credentials as environment variables
- Secrets are stored in Vault at path `secrets/mongo`
- Uses Kubernetes authentication method for Vault access

## Docker

The application includes a multi-stage Dockerfile for efficient container builds:
- Uses Go 1.21 Alpine for building
- Final image based on Alpine Linux for minimal size
- Exposes port 8080

## Dependencies

- `github.com/gorilla/mux`: HTTP router and URL matcher
- `go.mongodb.org/mongo-driver`: Official MongoDB driver for Go

## Health Check

The application includes a health check endpoint at `/health` that returns:
```json
{
  "status": "healthy",
  "timestamp": "2023-12-01T12:00:00Z",
  "service": "golang-app"
}
```

## Sample Usage

### Create a user:
```bash
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -d '{"name": "John Doe", "email": "john@example.com", "age": 30}'
```

### Get all users:
```bash
curl http://localhost:8080/api/users
```
