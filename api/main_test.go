package main

import "testing"

func TestListenAddr(t *testing.T) {
	cases := []struct {
		name, host, port, want string
	}{
		{"defaults stay on loopback", "", "", "127.0.0.1:9999"},
		{"port only", "", "18080", "127.0.0.1:18080"},
		{"container bind", "0.0.0.0", "9999", "0.0.0.0:9999"},
		{"ipv6 host is bracketed", "::", "9999", "[::]:9999"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("API_HOST", tc.host)
			t.Setenv("API_PORT", tc.port)
			if got := listenAddr(); got != tc.want {
				t.Fatalf("listenAddr() = %q, want %q", got, tc.want)
			}
		})
	}
}
