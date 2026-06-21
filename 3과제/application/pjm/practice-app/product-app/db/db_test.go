package db

import (
	"strings"
	"testing"
)

func TestConfigFromEnv(t *testing.T) {
	t.Setenv("MYSQL_USER", "appuser")
	t.Setenv("MYSQL_PASSWORD", "apppass")
	t.Setenv("MYSQL_HOST", "127.0.0.1")
	t.Setenv("MYSQL_PORT", "3306")
	t.Setenv("MYSQL_DBNAME", "dev")
	c, err := ConfigFromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(c.DSN(), "tcp(127.0.0.1:3306)/dev") {
		t.Fatalf("dsn: %s", c.DSN())
	}
}
