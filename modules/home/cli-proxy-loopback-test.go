package nixlocal

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLocalBoundary(t *testing.T) {
	for _, tc := range []struct {
		name, peer, host, origin string
		status                   int
	}{
		{"local without credentials", "127.0.0.1:50000", "127.0.0.1:18317", "", 204},
		{"local dashboard forwarded to gateway", "127.0.0.1:50000", "127.0.0.1:8317", "http://localhost:18317", 204},
		{"local browser", "127.0.0.1:50000", "localhost:18317", "http://localhost:18317", 204},
		{"forwarded header cannot grant local access", "192.0.2.1:50000", "127.0.0.1:18317", "", 403},
		{"foreign host", "127.0.0.1:50000", "example.invalid:18317", "", 403},
		{"foreign browser origin", "127.0.0.1:50000", "127.0.0.1:18317", "https://example.invalid", 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest("GET", "http://"+tc.host+"/", nil)
			request.RemoteAddr = tc.peer
			request.Header.Set("Origin", tc.origin)
			request.Header.Set("X-Forwarded-For", "127.0.0.1")
			response := httptest.NewRecorder()
			Wrap(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) })).ServeHTTP(response, request)
			if response.Code != tc.status {
				t.Fatalf("status = %d, want %d", response.Code, tc.status)
			}
		})
	}
}
