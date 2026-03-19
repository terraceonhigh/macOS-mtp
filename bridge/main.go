package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"

	"macos-mtp/bridge/mtp"
	"macos-mtp/bridge/webdav"
)

func main() {
	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	// Bind to a random localhost port first, before device detection.
	// This lets us fail fast on port issues.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}
	port := listener.Addr().(*net.TCPAddr).Port

	log.Println("Detecting MTP device...")
	session, err := mtp.NewSession()
	if err != nil {
		log.Fatalf("MTP session failed: %v", err)
	}
	defer session.Close()

	deviceName := session.DeviceName()
	log.Printf("Connected to: %s", deviceName)

	handler := webdav.NewHandler(session)

	// Print port in structured format for the Swift app to read from stdout.
	fmt.Fprintf(os.Stdout, "PORT=%d\n", port)
	fmt.Fprintf(os.Stdout, "DEVICE=%s\n", deviceName)
	os.Stdout.Sync()

	log.Printf("WebDAV server listening on http://127.0.0.1:%d/", port)
	log.Printf("Mount with: Finder → Go → Connect to Server → dav://localhost:%d/", port)

	if err := http.Serve(listener, handler); err != nil {
		log.Fatalf("HTTP server error: %v", err)
	}
}
