// vsock-bridge listens on the given AF_VSOCK ports and forwards each connection to the matching
// 127.0.0.1 TCP port inside the guest. The host reaches astro/MCP (which speak TCP) by dialing
// these vsock ports; this bridge is the vsock↔TCP shim. Usage: vsock-bridge 4321:4321 4399:4399
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

	"golang.org/x/sys/unix"
)

func main() {
	log.Printf("vsock-bridge: process started, args=%v", os.Args[1:])
	for _, arg := range os.Args[1:] {
		parts := strings.SplitN(arg, ":", 2)
		if len(parts) != 2 {
			log.Printf("skipping malformed arg %q (want vport:tport)", arg)
			continue
		}
		vport, err := strconv.Atoi(parts[0])
		if err != nil {
			log.Printf("skipping malformed arg %q: bad vport: %v", arg, err)
			continue
		}
		tport, err := strconv.Atoi(parts[1])
		if err != nil || tport < 1 || tport > 65535 {
			log.Printf("skipping malformed arg %q: bad tport: %v", arg, err)
			continue
		}
		go listen(uint32(vport), strconv.Itoa(tport))
	}
	// No signal handling: LinuxContainer.stop() tears down the whole VM, which kills
	// this process and all goroutines — per-process cleanup is unnecessary.
	select {}
}

func listen(vport uint32, tcpPort string) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Printf("vsock-bridge: socket(AF_VSOCK) vport=%d: %v", vport, err)
		return
	}
	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: vport}
	if err := unix.Bind(fd, sa); err != nil {
		log.Printf("vsock-bridge: bind vport=%d: %v", vport, err)
		unix.Close(fd)
		return
	}
	if err := unix.Listen(fd, 16); err != nil {
		log.Printf("vsock-bridge: listen vport=%d: %v", vport, err)
		unix.Close(fd)
		return
	}
	log.Printf("vsock-bridge: listening on vport=%d, forwarding to 127.0.0.1:%s", vport, tcpPort)
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil {
			// Transient errors: retry without spinning.
			if errors.Is(err, syscall.EINTR) || errors.Is(err, syscall.EAGAIN) || errors.Is(err, syscall.ECONNABORTED) {
				continue
			}
			// Permanent error (e.g. EBADF = listener closed): stop accepting on this port.
			log.Printf("vsock-bridge: accept vport=%d: %v — listener closed", vport, err)
			return
		}
		log.Printf("vsock-bridge: accept vport=%d succeeded", vport)
		go splice(nfd, tcpPort)
	}
}

// closeWriter is the half-close interface supported by *net.TCPConn and similar.
type closeWriter interface {
	CloseWrite() error
}

func splice(vfd int, tcpPort string) {
	vconn, err := osConn(vfd)
	if err != nil {
		log.Printf("vsock-bridge: osConn tport=%s: %v", tcpPort, err)
		unix.Close(vfd)
		return
	}
	log.Printf("vsock-bridge: accepted vsock conn, dialing 127.0.0.1:%s", tcpPort)
	tconn, err := net.Dial("tcp", "127.0.0.1:"+tcpPort)
	if err != nil {
		log.Printf("vsock-bridge: dial 127.0.0.1:%s failed: %v", tcpPort, err)
		vconn.Close()
		return
	}
	log.Printf("vsock-bridge: dial 127.0.0.1:%s succeeded, splicing", tcpPort)

	var wg sync.WaitGroup
	wg.Add(2)

	// vsock → TCP
	go func() {
		defer wg.Done()
		n, err := io.Copy(tconn, vconn)
		log.Printf("vsock-bridge: vsock->tcp(%s) done: %d bytes, err=%v", tcpPort, n, err)
		// Signal EOF to the TCP side without closing the read direction.
		if cw, ok := tconn.(closeWriter); ok {
			cw.CloseWrite()
		} else {
			tconn.Close()
		}
	}()

	// TCP → vsock
	go func() {
		defer wg.Done()
		n, err := io.Copy(vconn, tconn)
		log.Printf("vsock-bridge: tcp->vsock(%s) done: %d bytes, err=%v", tcpPort, n, err)
		// Signal EOF to the vsock side without closing the read direction.
		if cw, ok := vconn.(closeWriter); ok {
			cw.CloseWrite()
		} else {
			vconn.Close()
		}
	}()

	wg.Wait()
	tconn.Close()
	vconn.Close()
}

func osConn(fd int) (net.Conn, error) {
	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock-%d", fd))
	c, err := net.FileConn(f) // net.FileConn dup's the fd
	f.Close()
	if err != nil {
		return nil, err
	}
	return c, nil
}
