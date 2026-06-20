// 5gpn-tcp-proxy.go - TCP Host/SNI proxy with optional SOCKS5 egress.
//
// Listens on TCP :80 and :443, extracts HTTP Host or TLS SNI, then connects to
// the real target either directly or through a SOCKS5 outbound such as Xray.
//
// Build: go build -o 5gpn-tcp-proxy 5gpn-tcp-proxy.go

package main

import (
	"bufio"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	httpListenAddr  = flag.String("http", "0.0.0.0:80", "HTTP listen address")
	httpsListenAddr = flag.String("https", "0.0.0.0:443", "HTTPS listen address")
	egressMode      = flag.String("egress", "direct", "Egress mode: direct or socks5")
	socks5Addr      = flag.String("socks5", "127.0.0.1:1080", "SOCKS5 server address")
	socks5User      = flag.String("socks5-user", "", "SOCKS5 username")
	socks5Pass      = flag.String("socks5-pass", "", "SOCKS5 password")
	dialTimeout     = flag.Duration("dial-timeout", 10*time.Second, "Outbound dial timeout")
	debugLog        = flag.Bool("debug", false, "Enable verbose logging")
)

func main() {
	flag.Parse()
	mode := strings.ToLower(strings.TrimSpace(*egressMode))
	if mode != "direct" && mode != "socks5" {
		log.Fatalf("unsupported egress mode: %s", *egressMode)
	}

	log.Printf("5gpn-tcp-proxy starting (egress=%s, socks5=%s)", mode, *socks5Addr)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		serveTCP(*httpListenAddr, "http", mode)
	}()
	go func() {
		defer wg.Done()
		serveTCP(*httpsListenAddr, "https", mode)
	}()
	wg.Wait()
}

func serveTCP(listenAddr, proto, mode string) {
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("listen %s %s: %v", proto, listenAddr, err)
	}
	defer ln.Close()
	log.Printf("%s listener ready on %s", proto, listenAddr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("%s accept: %v", proto, err)
			continue
		}
		go handleClient(conn, proto, mode)
	}
}

func handleClient(client net.Conn, proto, mode string) {
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(15 * time.Second))

	host, port, firstBytes, err := inspectClientHello(client, proto)
	if err != nil {
		log.Printf("[%s] inspect %s failed: %v", client.RemoteAddr(), proto, err)
		return
	}
	_ = client.SetDeadline(time.Time{})

	target := net.JoinHostPort(host, strconv.Itoa(port))
	upstream, err := dialTarget(mode, host, port)
	if err != nil {
		log.Printf("[%s] dial %s via %s failed: %v", client.RemoteAddr(), target, mode, err)
		return
	}
	defer upstream.Close()

	if len(firstBytes) > 0 {
		if _, err := upstream.Write(firstBytes); err != nil {
			log.Printf("[%s] write initial bytes to %s failed: %v", client.RemoteAddr(), target, err)
			return
		}
	}

	log.Printf("[%s] %s %s via %s", client.RemoteAddr(), proto, target, mode)
	relay(client, upstream)
}

func inspectClientHello(conn net.Conn, proto string) (string, int, []byte, error) {
	switch proto {
	case "http":
		return inspectHTTP(conn)
	case "https":
		return inspectTLS(conn)
	default:
		return "", 0, nil, errors.New("unknown protocol")
	}
}

func inspectHTTP(conn net.Conn) (string, int, []byte, error) {
	reader := bufio.NewReader(conn)
	var data []byte
	for len(data) < 64*1024 {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			data = append(data, line...)
		}
		if err != nil {
			return "", 0, data, err
		}
		if len(data) >= 4 && strings.Contains(string(data), "\r\n\r\n") {
			if buffered := reader.Buffered(); buffered > 0 {
				extra := make([]byte, buffered)
				if _, err := io.ReadFull(reader, extra); err == nil {
					data = append(data, extra...)
				}
			}
			break
		}
	}

	host := parseHTTPHost(string(data))
	if host == "" {
		return "", 0, data, errors.New("missing HTTP Host header")
	}
	host, port := splitHostPortDefault(host, 80)
	return host, port, data, nil
}

func parseHTTPHost(header string) string {
	scanner := bufio.NewScanner(strings.NewReader(header))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.EqualFold(strings.TrimSpace(line), "") {
			break
		}
		if i := strings.IndexByte(line, ':'); i > 0 && strings.EqualFold(line[:i], "Host") {
			return strings.TrimSpace(line[i+1:])
		}
	}
	return ""
}

func inspectTLS(conn net.Conn) (string, int, []byte, error) {
	header := make([]byte, 5)
	if _, err := io.ReadFull(conn, header); err != nil {
		return "", 0, header, err
	}
	if header[0] != 0x16 {
		return "", 0, header, fmt.Errorf("not a TLS handshake record: 0x%02x", header[0])
	}
	recordLen := int(binary.BigEndian.Uint16(header[3:5]))
	if recordLen <= 0 || recordLen > 64*1024 {
		return "", 0, header, fmt.Errorf("invalid TLS record length: %d", recordLen)
	}
	body := make([]byte, recordLen)
	if _, err := io.ReadFull(conn, body); err != nil {
		return "", 0, append(header, body...), err
	}
	firstBytes := append(header, body...)
	sni, err := parseTLSSNI(body)
	if err != nil {
		return "", 0, firstBytes, err
	}
	return sni, 443, firstBytes, nil
}

func parseTLSSNI(body []byte) (string, error) {
	if len(body) < 4 || body[0] != 0x01 {
		return "", errors.New("not a TLS ClientHello")
	}
	hsLen := int(body[1])<<16 | int(body[2])<<8 | int(body[3])
	if hsLen+4 > len(body) {
		return "", errors.New("truncated TLS ClientHello")
	}
	p := 4
	if p+2+32 > len(body) {
		return "", errors.New("truncated TLS version/random")
	}
	p += 2 + 32
	if p >= len(body) {
		return "", errors.New("truncated session id")
	}
	sessionLen := int(body[p])
	p += 1 + sessionLen
	if p+2 > len(body) {
		return "", errors.New("truncated cipher suites")
	}
	cipherLen := int(binary.BigEndian.Uint16(body[p : p+2]))
	p += 2 + cipherLen
	if p >= len(body) {
		return "", errors.New("truncated compression methods")
	}
	compressionLen := int(body[p])
	p += 1 + compressionLen
	if p+2 > len(body) {
		return "", errors.New("missing extensions")
	}
	extensionsLen := int(binary.BigEndian.Uint16(body[p : p+2]))
	p += 2
	end := p + extensionsLen
	if end > len(body) {
		return "", errors.New("truncated extensions")
	}
	for p+4 <= end {
		extType := binary.BigEndian.Uint16(body[p : p+2])
		extLen := int(binary.BigEndian.Uint16(body[p+2 : p+4]))
		p += 4
		if p+extLen > end {
			return "", errors.New("truncated extension")
		}
		if extType == 0x0000 {
			return parseSNIExtension(body[p : p+extLen])
		}
		p += extLen
	}
	return "", errors.New("SNI extension not found")
}

func parseSNIExtension(data []byte) (string, error) {
	if len(data) < 2 {
		return "", errors.New("truncated SNI list")
	}
	listLen := int(binary.BigEndian.Uint16(data[:2]))
	p := 2
	end := p + listLen
	if end > len(data) {
		return "", errors.New("invalid SNI list length")
	}
	for p+3 <= end {
		nameType := data[p]
		nameLen := int(binary.BigEndian.Uint16(data[p+1 : p+3]))
		p += 3
		if p+nameLen > end {
			return "", errors.New("truncated SNI name")
		}
		if nameType == 0 {
			name := strings.TrimSpace(string(data[p : p+nameLen]))
			if name != "" {
				return name, nil
			}
		}
		p += nameLen
	}
	return "", errors.New("host_name SNI not found")
}

func splitHostPortDefault(input string, defaultPort int) (string, int) {
	input = strings.TrimSpace(input)
	if host, portText, err := net.SplitHostPort(input); err == nil {
		if port, err := strconv.Atoi(portText); err == nil && port > 0 {
			return strings.Trim(host, "[]"), port
		}
	}
	if i := strings.LastIndex(input, ":"); i > -1 && strings.Count(input, ":") == 1 {
		if port, err := strconv.Atoi(input[i+1:]); err == nil && port > 0 {
			return input[:i], port
		}
	}
	return strings.Trim(input, "[]"), defaultPort
}

func dialTarget(mode, host string, port int) (net.Conn, error) {
	switch mode {
	case "direct":
		return net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), *dialTimeout)
	case "socks5":
		return dialSOCKS5(host, port)
	default:
		return nil, errors.New("unsupported egress mode")
	}
}

func dialSOCKS5(host string, port int) (net.Conn, error) {
	conn, err := net.DialTimeout("tcp", *socks5Addr, *dialTimeout)
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Now().Add(*dialTimeout))

	methods := []byte{0x00}
	if *socks5User != "" || *socks5Pass != "" {
		methods = append(methods, 0x02)
	}
	if _, err := conn.Write([]byte{0x05, byte(len(methods))}); err != nil {
		conn.Close()
		return nil, err
	}
	if _, err := conn.Write(methods); err != nil {
		conn.Close()
		return nil, err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		conn.Close()
		return nil, err
	}
	if reply[0] != 0x05 {
		conn.Close()
		return nil, errors.New("invalid SOCKS5 handshake response")
	}
	if reply[1] == 0xff {
		conn.Close()
		return nil, errors.New("SOCKS5 server rejected authentication methods")
	}
	if reply[1] == 0x02 {
		if err := socks5UsernamePasswordAuth(conn, *socks5User, *socks5Pass); err != nil {
			conn.Close()
			return nil, err
		}
	} else if reply[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("unsupported SOCKS5 auth method: 0x%02x", reply[1])
	}

	if len(host) > 255 {
		conn.Close()
		return nil, errors.New("target host too long for SOCKS5 domain request")
	}
	req := []byte{0x05, 0x01, 0x00, 0x03, byte(len(host))}
	req = append(req, []byte(host)...)
	req = binary.BigEndian.AppendUint16(req, uint16(port))
	if _, err := conn.Write(req); err != nil {
		conn.Close()
		return nil, err
	}
	if err := readSOCKS5ConnectReply(conn); err != nil {
		conn.Close()
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}

func socks5UsernamePasswordAuth(conn net.Conn, user, pass string) error {
	if len(user) > 255 || len(pass) > 255 {
		return errors.New("SOCKS5 username/password too long")
	}
	req := []byte{0x01, byte(len(user))}
	req = append(req, []byte(user)...)
	req = append(req, byte(len(pass)))
	req = append(req, []byte(pass)...)
	if _, err := conn.Write(req); err != nil {
		return err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	if reply[0] != 0x01 || reply[1] != 0x00 {
		return errors.New("SOCKS5 username/password authentication failed")
	}
	return nil
}

func readSOCKS5ConnectReply(conn net.Conn) error {
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil {
		return err
	}
	if header[0] != 0x05 {
		return errors.New("invalid SOCKS5 connect response")
	}
	if header[1] != 0x00 {
		return fmt.Errorf("SOCKS5 connect failed with code 0x%02x", header[1])
	}
	var skip int
	switch header[3] {
	case 0x01:
		skip = 4
	case 0x03:
		lenByte := make([]byte, 1)
		if _, err := io.ReadFull(conn, lenByte); err != nil {
			return err
		}
		skip = int(lenByte[0])
	case 0x04:
		skip = 16
	default:
		return fmt.Errorf("unsupported SOCKS5 bind address type: 0x%02x", header[3])
	}
	buf := make([]byte, skip+2)
	_, err := io.ReadFull(conn, buf)
	return err
}

func relay(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	go copyAndClose(&wg, a, b)
	go copyAndClose(&wg, b, a)
	wg.Wait()
}

func copyAndClose(wg *sync.WaitGroup, dst, src net.Conn) {
	defer wg.Done()
	_, _ = io.Copy(dst, src)
	if tcp, ok := dst.(*net.TCPConn); ok {
		_ = tcp.CloseWrite()
	}
}
