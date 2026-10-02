// Package nixlocal supplies the request boundary for the local, key-free builds.
package nixlocal

import (
	"fmt"
	"net"
	"net/http"
	"net/url"
)

func RequireAddress(address string) {
	host, _, err := net.SplitHostPort(address)
	if err != nil || host != "127.0.0.1" {
		panic("this local build requires a 127.0.0.1 listener")
	}
}

func ValidateRequest(r *http.Request) error {
	peer, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || !net.ParseIP(peer).IsLoopback() {
		return fmt.Errorf("loopback requests only")
	}
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil || (host != "127.0.0.1" && host != "localhost" && host != "::1") {
		return fmt.Errorf("localhost host required")
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		u, err := url.Parse(origin)
		if err != nil || u.Scheme != "http" || u.Port() == "" || (u.Hostname() != "127.0.0.1" && u.Hostname() != "localhost" && u.Hostname() != "::1") {
			return fmt.Errorf("local origin required")
		}
	}
	return nil
}

func Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := ValidateRequest(r); err != nil {
			http.Error(w, err.Error(), http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}
