// Demo gRPC (h2c) echo origin for hop-trace.
//
// Records one line per RPC that actually reaches this process so suites can
// prove denies / fail-closed never hit the origin. Not a product service.
//
//	go run . <listen-addr> <hits-file>
//	go run . 127.0.0.1:18090 demo/.run/grpc-origin-hits.log
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

var (
	hitsPath string
	hitsMu   sync.Mutex
)

func record(r *http.Request) {
	hitsMu.Lock()
	defer hitsMu.Unlock()
	f, err := os.OpenFile(hitsPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	rid := r.Header.Get("x-request-id")
	if rid == "" {
		rid = "-"
	}
	_, _ = fmt.Fprintf(f, "%s %s rid=%s\n", r.Method, r.URL.Path, rid)
}

func readFrame(r io.Reader) ([]byte, error) {
	var hdr [5]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(hdr[1:])
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeFrame(w http.ResponseWriter, fl http.Flusher, payload []byte) error {
	var hdr [5]byte
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	if _, err := w.Write(payload); err != nil {
		return err
	}
	fl.Flush()
	return nil
}

func unary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", http.StatusMethodNotAllowed)
		return
	}
	payload, err := readFrame(r.Body)
	if err != nil && err != io.EOF {
		w.Header().Set("Grpc-Status", "13")
		w.Header().Set("Grpc-Message", err.Error())
		w.WriteHeader(http.StatusOK)
		return
	}
	record(r)
	// EchoReply{text: "pong"} as protobuf (field 1, length-delimited).
	_ = payload
	replyText := []byte("pong")
	reply := append([]byte{0x0a, byte(len(replyText))}, replyText...)
	w.Header().Set("Content-Type", "application/grpc")
	w.Header().Set("Trailer", "Grpc-Status, Grpc-Message")
	w.WriteHeader(http.StatusOK)
	var hdr [5]byte
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(reply)))
	_, _ = w.Write(hdr[:])
	_, _ = w.Write(reply)
	// Trailers must be set after the body and before the handler returns
	// (do not Flush beforehand — that can end the stream without trailers).
	w.Header().Set("Grpc-Status", "0")
	w.Header().Set("Grpc-Message", "")
}

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: grpc-echo <listen-addr> <hits-file>")
		os.Exit(2)
	}
	listenAddr := os.Args[1]
	hitsPath = os.Args[2]

	mux := http.NewServeMux()
	mux.HandleFunc("/echo.Echo/Unary", unary)

	h2s := &http2.Server{}
	handler := h2c.NewHandler(mux, h2s)
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		panic(err)
	}
	fmt.Fprintf(os.Stderr, "grpc-echo h2c listening %s hits=%s\n", listenAddr, hitsPath)
	srv := &http.Server{Handler: handler}
	_ = http2.ConfigureServer(srv, h2s)
	panic(srv.Serve(ln))
}
