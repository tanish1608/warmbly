package config

import (
	"context"
	"net/url"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
)

type ApiConfig struct {
	Hostname string
	GinMode  string

	// PublicURL is the externally reachable base URL of the API, used to build
	// OAuth redirect URIs. It is separate from Hostname because behind a proxy
	// or on Cloud Run the listen address (0.0.0.0:8080) is not the public URL.
	// Falls back to Hostname when unset.
	PublicURL string

	WebsocketURI   string
	AllowedOrigins []string
}

func (c *Config) LoadApiConfig(ctx context.Context) (*ApiConfig, error) {
	// For API host, check env vars first with sensible defaults
	hostName := c.GetStringOptional(ctx, "API_HOST", "api/host", "0.0.0.0:8080")
	publicURL := strings.TrimRight(c.GetStringOptional(ctx, "PUBLIC_API_URL", "api/public_url", ""), "/")
	if publicURL == "" {
		publicURL = hostName
	}

	websocketUri, err := c.GetString(ctx, "WEBSOCKET_URL", "api/websocket_uri")
	if err != nil {
		return nil, err
	}

	allowedOrigins := splitCSV(os.Getenv("CORS_ALLOW_ORIGINS"))
	if len(allowedOrigins) == 0 {
		allowedOrigins = appendOrigin(allowedOrigins, os.Getenv("APP_URL"))
		if origin := originFromURI(websocketUri); origin != "" {
			allowedOrigins = appendOrigin(allowedOrigins, origin)
		}
		if c.Env != "prod" {
			for _, origin := range []string{
				"http://localhost:3000",
				"http://127.0.0.1:3000",
				"http://localhost:4173",
				"http://127.0.0.1:4173",
				"http://localhost:5173",
				"http://127.0.0.1:5173",
				"http://localhost:5174",
				"http://127.0.0.1:5174",
			} {
				allowedOrigins = appendOrigin(allowedOrigins, origin)
			}
		}
	}

	// GIN_MODE from env, or derive from APP_ENV
	ginMode := os.Getenv("GIN_MODE")
	if ginMode == "" {
		if c.Env == "prod" {
			ginMode = gin.ReleaseMode
		} else {
			ginMode = gin.DebugMode
		}
	}

	return &ApiConfig{
		Hostname:       hostName,
		PublicURL:      publicURL,
		GinMode:        ginMode,
		WebsocketURI:   websocketUri,
		AllowedOrigins: allowedOrigins,
	}, nil
}

func splitCSV(value string) []string {
	if value == "" {
		return nil
	}

	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func appendOrigin(origins []string, origin string) []string {
	origin = strings.TrimSpace(origin)
	if origin == "" {
		return origins
	}
	for _, existing := range origins {
		if existing == origin {
			return origins
		}
	}
	return append(origins, origin)
}

func originFromURI(raw string) string {
	if raw == "" {
		return ""
	}

	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}

	scheme := u.Scheme
	switch scheme {
	case "ws":
		scheme = "http"
	case "wss":
		scheme = "https"
	}
	if scheme == "" {
		return ""
	}

	return scheme + "://" + u.Host
}
