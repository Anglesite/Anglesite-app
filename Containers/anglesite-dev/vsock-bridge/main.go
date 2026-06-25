// vsock-bridge listens on the given AF_VSOCK ports and forwards each connection to the matching
// 127.0.0.1 TCP port inside the guest. The host reaches astro/MCP (which speak TCP) by dialing
// these vsock ports; this bridge is the vsock↔TCP shim. Usage: vsock-bridge 4321:4321 4399:4399
package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

func main() {
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
		go listen(uint32(vport), parts[1])
	}
	select {} // run forever
}

func listen(vport uint32, tcpPort string) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil { panic(err) }
	sa := &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: vport}
	if err := unix.Bind(fd, sa); err != nil { panic(err) }
	if err := unix.Listen(fd, 16); err != nil { panic(err) }
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil { continue }
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
		unix.Close(vfd)
		return
	}
	tconn, err := net.Dial("tcp", "127.0.0.1:"+tcpPort)
	if err != nil {
		vconn.Close()
		return
	}

	var wg sync.WaitGroup
	wg.Add(2)

	// vsock → TCP
	go func() {
		defer wg.Done()
		io.Copy(tconn, vconn)
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
		io.Copy(vconn, tconn)
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
