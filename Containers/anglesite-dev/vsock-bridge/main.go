// vsock-bridge listens on the given AF_VSOCK ports and forwards each connection to the matching
// 127.0.0.1 TCP port inside the guest. The host reaches astro/MCP (which speak TCP) by dialing
// these vsock ports; this bridge is the vsock↔TCP shim. Usage: vsock-bridge 4321:4321 4399:4399
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func main() {
	for _, arg := range os.Args[1:] {
		parts := strings.SplitN(arg, ":", 2)
		vport, _ := strconv.Atoi(parts[0])
		tport := parts[1]
		go listen(uint32(vport), tport)
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

func splice(vfd int, tcpPort string) {
	vconn := osConn(vfd)
	tconn, err := net.Dial("tcp", "127.0.0.1:"+tcpPort)
	if err != nil { vconn.Close(); return }
	go func() { io.Copy(tconn, vconn); tconn.Close() }()
	io.Copy(vconn, tconn); vconn.Close()
}

func osConn(fd int) net.Conn {
	f := os.NewFile(uintptr(fd), fmt.Sprintf("vsock-%d", fd))
	c, _ := net.FileConn(f) // net.FileConn dup's the fd
	f.Close()
	return c
}
