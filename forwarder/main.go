// titan-fwd runs inside a Titan VM and makes the app reachable from the Mac no matter
// which address it binds.
//
// Apple's container port publishing delivers traffic to the VM's network interface, so a
// dev server bound to 127.0.0.1 (Vite, Django, Flask, Rails…) is unreachable. Titan
// publishes each Mac port to a forwarder port instead (61000+), and this program relays
// every connection to the app's real port on 127.0.0.1, then ::1, then the VM's own
// addresses. It never listens on the app's port, so apps binding 0.0.0.0 still start.
//
// Usage: titan-fwd LISTEN:TARGET [LISTEN:TARGET...]   e.g. titan-fwd 61000:3000 61001:5173
package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: titan-fwd LISTEN:TARGET [LISTEN:TARGET...]")
		os.Exit(2)
	}
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	var wg sync.WaitGroup
	started := 0
	for _, spec := range os.Args[1:] {
		listen, target, err := parse(spec)
		if err != nil {
			log.Fatalf("bad mapping %q: %v", spec, err)
		}
		ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", listen))
		if err != nil {
			if errors.Is(err, syscall.EADDRINUSE) {
				log.Printf("port %d already forwarded (another titan-fwd is running)", listen)
				continue
			}
			log.Fatalf("listen %d: %v", listen, err)
		}
		started++
		log.Printf("forwarding :%d -> app port %d", listen, target)
		wg.Add(1)
		go func() { defer wg.Done(); serve(ln, target) }()
	}
	if started == 0 {
		return
	}
	wg.Wait()
}

func parse(spec string) (int, int, error) {
	a, b, ok := strings.Cut(spec, ":")
	if !ok {
		return 0, 0, errors.New("want LISTEN:TARGET")
	}
	l, err1 := strconv.Atoi(a)
	t, err2 := strconv.Atoi(b)
	if err1 != nil || err2 != nil || l <= 0 || t <= 0 || l > 65535 || t > 65535 {
		return 0, 0, errors.New("ports must be 1-65535")
	}
	return l, t, nil
}

func serve(ln net.Listener, target int) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go relay(conn, target)
	}
}

// candidates lists where the app might be listening, loopback first.
func candidates(target int) []string {
	port := strconv.Itoa(target)
	out := []string{net.JoinHostPort("127.0.0.1", port), net.JoinHostPort("::1", port)}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && !ipnet.IP.IsLinkLocalUnicast() {
			out = append(out, net.JoinHostPort(ipnet.IP.String(), port))
		}
	}
	return out
}

func relay(client net.Conn, target int) {
	defer client.Close()
	var upstream net.Conn
	for _, addr := range candidates(target) {
		c, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			upstream = c
			break
		}
	}
	if upstream == nil {
		return // app not listening yet: the client sees the connection close
	}
	defer upstream.Close()
	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		io.Copy(dst, src)
		if tcp, ok := dst.(*net.TCPConn); ok {
			tcp.CloseWrite() // half-close so request/response streams end cleanly
		}
		done <- struct{}{}
	}
	go pipe(upstream, client)
	go pipe(client, upstream)
	<-done
	<-done
}
