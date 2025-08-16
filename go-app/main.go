package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/gorilla/mux"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

type User struct {
	ID    primitive.ObjectID `bson:"_id,omitempty" json:"id,omitempty"`
	Name  string             `bson:"name" json:"name"`
	Email string             `bson:"email" json:"email"`
	Age   int                `bson:"age" json:"age"`
}

type App struct {
	client *mongo.Client
	db     *mongo.Database
}

func NewApp() *App {
	return &App{}
}

func readVaultSecrets() (string, string, error) {
	// Try to read from Vault injected file first
	secretsFile := "/vault/secrets/mongo"
	if file, err := os.Open(secretsFile); err == nil {
		defer file.Close()
		
		var mongoUser, mongoPassword string
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if strings.HasPrefix(line, "export MONGO_USER=") {
				mongoUser = strings.Trim(strings.TrimPrefix(line, "export MONGO_USER="), `"`)
			} else if strings.HasPrefix(line, "export MONGO_PASSWORD=") {
				mongoPassword = strings.Trim(strings.TrimPrefix(line, "export MONGO_PASSWORD="), `"`)
			}
		}
		
		if mongoUser != "" && mongoPassword != "" {
			return mongoUser, mongoPassword, nil
		}
	}
	
	// Fallback to environment variables
	mongoUser := os.Getenv("MONGO_USER")
	mongoPassword := os.Getenv("MONGO_PASSWORD")
	
	if mongoUser == "" || mongoPassword == "" {
		return "", "", fmt.Errorf("MongoDB credentials not found in Vault secrets file or environment variables")
	}
	
	return mongoUser, mongoPassword, nil
}

func (a *App) connectToMongoDB() error {
	// Read MongoDB credentials from Vault injected files or environment variables
	mongoUser, mongoPassword, err := readVaultSecrets()
	if err != nil {
		return err
	}

	log.Printf("Successfully read credentials from Vault - User: %s, Password: %s", mongoUser, "***hidden***")

	// MongoDB connection string
	mongoURI := fmt.Sprintf("mongodb://%s:%s@mongodb.mongo-vault-operator.svc.cluster.local:27017/appdb", mongoUser, mongoPassword)
	
	// Set client options
	clientOptions := options.Client().ApplyURI(mongoURI)

	// Connect to MongoDB
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	client, err := mongo.Connect(ctx, clientOptions)
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
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(map[string]string{"error": "Invalid JSON"})
		return
	}

	// Insert user into MongoDB
	collection := a.db.Collection("users")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	result, err := collection.InsertOne(ctx, user)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "Failed to create user"})
		return
	}

	user.ID = result.InsertedID.(primitive.ObjectID)
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(user)
}

func (a *App) getUsers(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	collection := a.db.Collection("users")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	cursor, err := collection.Find(ctx, bson.M{})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "Failed to fetch users"})
		return
	}
	defer cursor.Close(ctx)

	var users []User
	if err = cursor.All(ctx, &users); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(map[string]string{"error": "Failed to decode users"})
		return
	}

	if users == nil {
		users = []User{}
	}

	json.NewEncoder(w).Encode(users)
}

func (a *App) healthCheck(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{
		"status":    "healthy",
		"timestamp": time.Now().Format(time.RFC3339),
		"service":   "golang-app",
	})
}

func main() {
	app := NewApp()

	// Connect to MongoDB with retry logic
	var err error
	for i := 0; i < 10; i++ {
		err = app.connectToMongoDB()
		if err == nil {
			break
		}
		log.Printf("Failed to connect to MongoDB (attempt %d/10): %v", i+1, err)
		time.Sleep(10 * time.Second)
	}

	if err != nil {
		log.Fatalf("Could not connect to MongoDB after 10 attempts: %v", err)
	}

	// Setup routes
	r := mux.NewRouter()
	
	// API routes
	r.HandleFunc("/api/users", app.createUser).Methods("POST")
	r.HandleFunc("/api/users", app.getUsers).Methods("GET")
	r.HandleFunc("/health", app.healthCheck).Methods("GET")

	// Start server
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("Server starting on port %s", port)
	log.Fatal(http.ListenAndServe(":"+port, r))
}
