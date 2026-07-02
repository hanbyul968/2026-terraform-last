package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

type User struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
	Age  int    `json:"age"`
}

var (
	users  = map[int]User{}
	lastID = 0
	mu     sync.Mutex
)

func main() {

	http.HandleFunc("/v1/users", usersHandler)
	http.HandleFunc("/v1/users/", userHandler)

	println("Server started :8080")
	http.ListenAndServe(":8080", nil)
}

func usersHandler(w http.ResponseWriter, r *http.Request) {

	switch r.Method {

	case http.MethodGet:
		list := []User{}

		mu.Lock()
		for _, u := range users {
			list = append(list, u)
		}
		mu.Unlock()

		json.NewEncoder(w).Encode(list)

	case http.MethodPost:
		var req struct {
			Name string `json:"name"`
			Age  int    `json:"age"`
		}

		json.NewDecoder(r.Body).Decode(&req)

		mu.Lock()
		lastID++
		user := User{
			ID:   lastID,
			Name: req.Name,
			Age:  req.Age,
		}
		users[user.ID] = user
		mu.Unlock()

		json.NewEncoder(w).Encode(user)

	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func userHandler(w http.ResponseWriter, r *http.Request) {

	idStr := strings.TrimPrefix(r.URL.Path, "/v1/users/")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "invalid id", 400)
		return
	}

	switch r.Method {

	case http.MethodGet:

		mu.Lock()
		user, ok := users[id]
		mu.Unlock()

		if !ok {
			http.NotFound(w, r)
			return
		}

		json.NewEncoder(w).Encode(user)

	case http.MethodDelete:

		mu.Lock()
		delete(users, id)
		mu.Unlock()

		w.WriteHeader(http.StatusNoContent)

	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}
