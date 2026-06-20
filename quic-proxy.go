// quic-proxy.go - Lightweight QUIC SNI transparent proxy
// Listens on UDP :443, extracts SNI from QUIC Initial packets (RFC 9000),
// then forwards UDP datagrams to the backend server.
//
// Pure Go standard library only (no external deps).
// Build: go build -o quic-proxy quic-proxy.go
// Run:   ./quic-proxy -l :443

package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	quicVersion1      = 0x00000001
	longHeaderForm    = 0x80
	initialPacketType = 0x00 // bits 4-5 of first byte = 00
	initialSaltV1     = "\x38\x76\x2c\xf7\xf5\x59\x34\xb3\x4d\x17\x9a\xe6\xa4\xc8\x0c\xad\xcc\xbb\x7f\x0a"
	tagSize           = 16
)

var (
	listenAddr  = flag.String("l", ":443", "Listen address (UDP)")
	idleTimeout = flag.Duration("idle-timeout", 300*time.Second, "UDP session idle timeout")
	debug       = flag.Bool("debug", false, "Enable debug logging")
	egressMode  = flag.String("egress", "direct", "Egress mode: direct or socks5")
	socks5Addr  = flag.String("socks5", "127.0.0.1:1080", "SOCKS5 server address for UDP ASSOCIATE")
	socks5User  = flag.String("socks5-user", "", "SOCKS5 username")
	socks5Pass  = flag.String("socks5-pass", "", "SOCKS5 password")
)

type Session struct {
	clientAddr   *net.UDPAddr
	backendConn  *net.UDPConn
	socksControl net.Conn
	targetHost   string
	targetPort   int
	egress       string
	lastActivity time.Time
	mu           sync.Mutex
}

type SessionManager struct {
	sessions map[string]*Session
	mu       sync.RWMutex
	listener *net.UDPConn
}

func main() {
	flag.Parse()
	if *debug {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}
	mode := strings.ToLower(strings.TrimSpace(*egressMode))
	if mode != "direct" && mode != "socks5" {
		log.Fatalf("unsupported egress mode: %s", *egressMode)
	}

	addr, err := net.ResolveUDPAddr("udp", *listenAddr)
	if err != nil {
		log.Fatalf("ResolveUDPAddr error: %v", err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("ListenUDP error: %v", err)
	}
	defer conn.Close()

	log.Printf("QUIC SNI Proxy listening on UDP %s (egress=%s, socks5=%s)", *listenAddr, mode, *socks5Addr)

	mgr := &SessionManager{
		sessions: make(map[string]*Session),
		listener: conn,
	}
	go mgr.gcLoop()

	buf := make([]byte, 65535)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if !os.IsTimeout(err) {
				log.Printf("ReadFromUDP error: %v", err)
			}
			continue
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		go mgr.handlePacket(data, clientAddr)
	}
}

func (m *SessionManager) handlePacket(data []byte, clientAddr *net.UDPAddr) {
	key := clientAddr.String()

	m.mu.RLock()
	sess, exists := m.sessions[key]
	m.mu.RUnlock()

	if exists {
		sess.mu.Lock()
		sess.lastActivity = time.Now()
		bc := sess.backendConn
		payload := data
		if sess.egress == "socks5" {
			payload = wrapSOCKS5UDP(sess.targetHost, sess.targetPort, data)
		}
		sess.mu.Unlock()
		if bc != nil {
			if _, err := bc.Write(payload); err != nil {
				log.Printf("[%s] Write to backend error: %v", key, err)
			}
		}
		return
	}

	sni, ok := extractSNI(data)
	if !ok || sni == "" {
		if *debug {
			log.Printf("[%s] Not a QUIC Initial, drop", key)
		}
		return
	}

	var backendIP net.IP
	if strings.ToLower(strings.TrimSpace(*egressMode)) == "direct" {
		ips, err := net.LookupIP(sni)
		if err != nil || len(ips) == 0 {
			log.Printf("[%s] DNS lookup failed for '%s': %v", key, sni, err)
			return
		}
		var ok bool
		backendIP, ok = selectBackendIPv4(ips)
		if !ok {
			log.Printf("[%s] DNS lookup for '%s' returned no IPv4 address", key, sni)
			return
		}
	}

	bc, control, err := dialUDPBackend(sni, backendIP, 443)
	if err != nil {
		log.Printf("[%s] Dial UDP backend for %s (%s) error: %v", key, sni, backendIP, err)
		return
	}

	sess = &Session{
		clientAddr:   clientAddr,
		backendConn:  bc,
		socksControl: control,
		targetHost:   sni,
		targetPort:   443,
		egress:       strings.ToLower(strings.TrimSpace(*egressMode)),
		lastActivity: time.Now(),
	}
	m.mu.Lock()
	m.sessions[key] = sess
	m.mu.Unlock()

	firstPayload := data
	if sess.egress == "socks5" {
		firstPayload = wrapSOCKS5UDP(sess.targetHost, sess.targetPort, data)
	}
	if _, err := bc.Write(firstPayload); err != nil {
		log.Printf("[%s] First packet forward error: %v", key, err)
		m.removeSession(key)
		return
	}

	go m.relayBackendToClient(sess, key)
	if *debug {
		log.Printf("[%s] New session to %s (%s) via %s", key, sni, backendIP, sess.egress)
	}
}

func dialUDPBackend(host string, ip net.IP, port int) (*net.UDPConn, net.Conn, error) {
	switch strings.ToLower(strings.TrimSpace(*egressMode)) {
	case "direct":
		backendAddr := &net.UDPAddr{IP: ip, Port: port}
		conn, err := net.DialUDP("udp", nil, backendAddr)
		return conn, nil, err
	case "socks5":
		return dialSOCKS5UDPAssociate(host, port)
	default:
		return nil, nil, errors.New("unsupported egress mode")
	}
}

func selectBackendIPv4(ips []net.IP) (net.IP, bool) {
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil {
			return ip4, true
		}
	}
	return nil, false
}

func dialSOCKS5UDPAssociate(host string, port int) (*net.UDPConn, net.Conn, error) {
	control, err := net.DialTimeout("tcp", *socks5Addr, 10*time.Second)
	if err != nil {
		return nil, nil, err
	}
	if err := control.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		control.Close()
		return nil, nil, err
	}

	methods := []byte{0x00}
	if *socks5User != "" || *socks5Pass != "" {
		methods = append(methods, 0x02)
	}
	if _, err := control.Write([]byte{0x05, byte(len(methods))}); err != nil {
		control.Close()
		return nil, nil, err
	}
	if _, err := control.Write(methods); err != nil {
		control.Close()
		return nil, nil, err
	}
	reply := make([]byte, 2)
	if _, err := io.ReadFull(control, reply); err != nil {
		control.Close()
		return nil, nil, err
	}
	if reply[0] != 0x05 || reply[1] == 0xff {
		control.Close()
		return nil, nil, errors.New("SOCKS5 UDP handshake rejected")
	}
	if reply[1] == 0x02 {
		if err := socks5UsernamePasswordAuth(control, *socks5User, *socks5Pass); err != nil {
			control.Close()
			return nil, nil, err
		}
	} else if reply[1] != 0x00 {
		control.Close()
		return nil, nil, fmt.Errorf("unsupported SOCKS5 auth method: 0x%02x", reply[1])
	}

	req := []byte{0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	if _, err := control.Write(req); err != nil {
		control.Close()
		return nil, nil, err
	}
	relayHost, relayPort, err := readSOCKS5ReplyAddress(control)
	if err != nil {
		control.Close()
		return nil, nil, err
	}
	if relayHost == "0.0.0.0" || relayHost == "::" {
		if host, _, err := net.SplitHostPort(*socks5Addr); err == nil {
			relayHost = host
		}
	}
	relayAddr, err := net.ResolveUDPAddr("udp", net.JoinHostPort(relayHost, strconv.Itoa(relayPort)))
	if err != nil {
		control.Close()
		return nil, nil, err
	}
	udpConn, err := net.DialUDP("udp", nil, relayAddr)
	if err != nil {
		control.Close()
		return nil, nil, err
	}
	_ = control.SetDeadline(time.Time{})
	return udpConn, control, nil
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

func readSOCKS5ReplyAddress(conn net.Conn) (string, int, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil {
		return "", 0, err
	}
	if header[0] != 0x05 {
		return "", 0, errors.New("invalid SOCKS5 response")
	}
	if header[1] != 0x00 {
		return "", 0, fmt.Errorf("SOCKS5 request failed with code 0x%02x", header[1])
	}
	host, err := readSOCKS5Address(conn, header[3])
	if err != nil {
		return "", 0, err
	}
	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(conn, portBytes); err != nil {
		return "", 0, err
	}
	return host, int(binary.BigEndian.Uint16(portBytes)), nil
}

func readSOCKS5Address(reader io.Reader, atyp byte) (string, error) {
	switch atyp {
	case 0x01:
		ip := make([]byte, 4)
		if _, err := io.ReadFull(reader, ip); err != nil {
			return "", err
		}
		return net.IP(ip).String(), nil
	case 0x03:
		lenByte := make([]byte, 1)
		if _, err := io.ReadFull(reader, lenByte); err != nil {
			return "", err
		}
		name := make([]byte, int(lenByte[0]))
		if _, err := io.ReadFull(reader, name); err != nil {
			return "", err
		}
		return string(name), nil
	case 0x04:
		ip := make([]byte, 16)
		if _, err := io.ReadFull(reader, ip); err != nil {
			return "", err
		}
		return net.IP(ip).String(), nil
	default:
		return "", fmt.Errorf("unsupported SOCKS5 address type: 0x%02x", atyp)
	}
}

func wrapSOCKS5UDP(host string, port int, payload []byte) []byte {
	out := []byte{0x00, 0x00, 0x00}
	if ip := net.ParseIP(host); ip != nil {
		if ip4 := ip.To4(); ip4 != nil {
			out = append(out, 0x01)
			out = append(out, ip4...)
		} else {
			out = append(out, 0x04)
			out = append(out, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			host = host[:255]
		}
		out = append(out, 0x03, byte(len(host)))
		out = append(out, []byte(host)...)
	}
	out = binary.BigEndian.AppendUint16(out, uint16(port))
	out = append(out, payload...)
	return out
}

func unwrapSOCKS5UDP(packet []byte) ([]byte, error) {
	if len(packet) < 4 {
		return nil, errors.New("short SOCKS5 UDP packet")
	}
	if packet[2] != 0x00 {
		return nil, errors.New("fragmented SOCKS5 UDP packet is unsupported")
	}
	p := 3
	switch packet[p] {
	case 0x01:
		p += 1 + 4
	case 0x03:
		if p+1 >= len(packet) {
			return nil, errors.New("short SOCKS5 UDP domain header")
		}
		p += 2 + int(packet[p+1])
	case 0x04:
		p += 1 + 16
	default:
		return nil, fmt.Errorf("unsupported SOCKS5 UDP address type: 0x%02x", packet[p])
	}
	if p+2 > len(packet) {
		return nil, errors.New("short SOCKS5 UDP port")
	}
	p += 2
	if p > len(packet) {
		return nil, errors.New("short SOCKS5 UDP payload")
	}
	return packet[p:], nil
}

func (m *SessionManager) relayBackendToClient(sess *Session, key string) {
	buf := make([]byte, 65535)
	for {
		n, err := sess.backendConn.Read(buf)
		if err != nil {
			if *debug {
				log.Printf("[%s] Backend read error: %v", key, err)
			}
			m.removeSession(key)
			return
		}
		sess.mu.Lock()
		sess.lastActivity = time.Now()
		sess.mu.Unlock()
		payload := buf[:n]
		if sess.egress == "socks5" {
			var err error
			payload, err = unwrapSOCKS5UDP(payload)
			if err != nil {
				if *debug {
					log.Printf("[%s] SOCKS5 UDP unwrap error: %v", key, err)
				}
				continue
			}
		}
		if _, err := m.listener.WriteToUDP(payload, sess.clientAddr); err != nil {
			log.Printf("[%s] WriteToUDP error: %v", key, err)
			m.removeSession(key)
			return
		}
	}
}

func (m *SessionManager) removeSession(key string) {
	m.mu.Lock()
	sess, ok := m.sessions[key]
	if ok {
		delete(m.sessions, key)
	}
	m.mu.Unlock()
	if ok && sess.backendConn != nil {
		sess.backendConn.Close()
	}
	if ok && sess.socksControl != nil {
		sess.socksControl.Close()
	}
}

func (m *SessionManager) gcLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		now := time.Now()
		var keys []string
		m.mu.RLock()
		for k, s := range m.sessions {
			s.mu.Lock()
			idle := now.Sub(s.lastActivity)
			s.mu.Unlock()
			if idle > *idleTimeout {
				keys = append(keys, k)
			}
		}
		m.mu.RUnlock()
		for _, k := range keys {
			m.removeSession(k)
			if *debug {
				log.Printf("[%s] GC idle session", k)
			}
		}
	}
}

// extractSNI decrypts a QUIC v1 Initial packet and returns the SNI hostname.
func extractSNI(data []byte) (string, bool) {
	if len(data) < 5 {
		return "", false
	}
	if data[0]&0x80 == 0 {
		return "", false // short header
	}
	version := binary.BigEndian.Uint32(data[1:5])
	if version != quicVersion1 {
		return "", false
	}
	pktType := (data[0] & 0x30) >> 4
	if pktType != initialPacketType {
		return "", false
	}

	off := 5
	if len(data) < off+1 {
		return "", false
	}
	dcidLen := int(data[off])
	off++
	if len(data) < off+dcidLen {
		return "", false
	}
	dcid := data[off : off+dcidLen]
	off += dcidLen

	if len(data) < off+1 {
		return "", false
	}
	scidLen := int(data[off])
	off++
	if len(data) < off+scidLen {
		return "", false
	}
	off += scidLen

	tokenLen, n := readVarint(data[off:])
	if n == 0 || len(data) < off+n+int(tokenLen) {
		return "", false
	}
	off += n + int(tokenLen)

	length, n := readVarint(data[off:])
	if n == 0 || uint64(len(data)-off) < length {
		return "", false
	}
	off += n
	if off+int(length) > len(data) {
		return "", false
	}
	protected := data[off : off+int(length)]

	// Derive keys
	initialSecret := hkdfExtract([]byte(initialSaltV1), dcid)
	clientInitialSecret := hkdfExpandLabel(initialSecret, "client in", nil, 32)
	key := hkdfExpandLabel(clientInitialSecret, "quic key", nil, 16)
	iv := hkdfExpandLabel(clientInitialSecret, "quic iv", nil, 12)
	hp := hkdfExpandLabel(clientInitialSecret, "quic hp", nil, 16)

	// Header protection (AES-128-ECB)
	hpCipher, err := aes.NewCipher(hp)
	if err != nil {
		return "", false
	}
	if len(protected) < 5 {
		return "", false
	}
	sampleOffset := 4
	if len(protected) < sampleOffset+16 {
		sampleOffset = 0
	}
	if sampleOffset+16 > len(protected) {
		return "", false
	}
	sample := protected[sampleOffset : sampleOffset+16]
	mask := make([]byte, 16)
	hpCipher.Encrypt(mask, sample)

	firstByte := data[0] ^ (mask[0] & 0x1f)
	pnLen := int(firstByte&0x03) + 1
	if len(protected) < pnLen {
		return "", false
	}
	packetNumber := make([]byte, pnLen)
	for i := 0; i < pnLen; i++ {
		packetNumber[i] = protected[i] ^ mask[1+i]
	}
	pn := 0
	for i := 0; i < pnLen; i++ {
		pn = (pn << 8) | int(packetNumber[i])
	}

	// Nonce = iv XOR packet_number (left-padded)
	nonce := make([]byte, 12)
	copy(nonce, iv)
	for i := 0; i < pnLen; i++ {
		nonce[11-i] ^= packetNumber[pnLen-1-i]
	}

	// AEAD decrypt
	aesBlock, err := aes.NewCipher(key)
	if err != nil {
		return "", false
	}
	aead, err := cipher.NewGCM(aesBlock)
	if err != nil {
		return "", false
	}

	aad := make([]byte, off+pnLen)
	copy(aad, data[:off+pnLen])
	aad[0] = firstByte
	copy(aad[off:], packetNumber)

	ciphertext := protected[pnLen:]
	if len(ciphertext) < tagSize {
		return "", false
	}
	plaintext, err := aead.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return "", false
	}

	return parseCryptoFrames(plaintext)
}

func readVarint(buf []byte) (uint64, int) {
	if len(buf) == 0 {
		return 0, 0
	}
	first := buf[0]
	prefix := first >> 6
	length := 1 << prefix
	if len(buf) < length {
		return 0, 0
	}
	var val uint64
	switch length {
	case 1:
		val = uint64(first & 0x3f)
	case 2:
		val = uint64(first&0x3f)<<8 | uint64(buf[1])
	case 4:
		val = uint64(first&0x3f)<<24 | uint64(buf[1])<<16 | uint64(buf[2])<<8 | uint64(buf[3])
	case 8:
		val = binary.BigEndian.Uint64(buf)
		val &= 0x3fffffffffffffff
	}
	return val, length
}

// HKDF-Extract with SHA-256 (RFC 5869)
func hkdfExtract(salt, ikm []byte) []byte {
	mac := hmac.New(sha256.New, salt)
	mac.Write(ikm)
	return mac.Sum(nil)
}

// HKDF-Expand (RFC 5869)
func hkdfExpand(prk []byte, info []byte, length int) []byte {
	var okm []byte
	var prev []byte
	n := (length + sha256.Size - 1) / sha256.Size
	for i := 1; i <= n; i++ {
		mac := hmac.New(sha256.New, prk)
		mac.Write(prev)
		mac.Write(info)
		mac.Write([]byte{byte(i)})
		prev = mac.Sum(nil)
		okm = append(okm, prev...)
	}
	return okm[:length]
}

// HKDF-Expand-Label (RFC 8446)
func hkdfExpandLabel(secret []byte, label string, context []byte, length int) []byte {
	qlabel := "tls13 " + label
	lbl := make([]byte, 0, 2+1+len(qlabel)+1+len(context))
	lbl = append(lbl, byte(length>>8), byte(length))
	lbl = append(lbl, byte(len(qlabel)))
	lbl = append(lbl, qlabel...)
	lbl = append(lbl, byte(len(context)))
	lbl = append(lbl, context...)
	return hkdfExpand(secret, lbl, length)
}

// parseCryptoFrames scans QUIC frames for a CRYPTO frame containing ClientHello.
func parseCryptoFrames(plaintext []byte) (string, bool) {
	off := 0
	for off < len(plaintext) {
		if off >= len(plaintext) {
			break
		}
		frameType := plaintext[off]
		off++
		switch frameType {
		case 0x00:
			for off < len(plaintext) && plaintext[off] == 0x00 {
				off++
			}
		case 0x06:
			_, n := readVarint(plaintext[off:])
			if n == 0 {
				return "", false
			}
			off += n
			dataLen, n := readVarint(plaintext[off:])
			if n == 0 || uint64(len(plaintext)-off) < dataLen {
				return "", false
			}
			off += n
			data := plaintext[off : off+int(dataLen)]
			sni, ok := extractSNIFromClientHello(data)
			if ok && sni != "" {
				return sni, true
			}
			off += int(dataLen)
		case 0x01, 0x02, 0x03:
			_, n := readVarint(plaintext[off:])
			if n == 0 {
				return "", false
			}
			off += n
			_, n = readVarint(plaintext[off:])
			if n == 0 {
				return "", false
			}
			off += n
			ackRangeCount, n := readVarint(plaintext[off:])
			if n == 0 {
				return "", false
			}
			off += n
			_, n = readVarint(plaintext[off:])
			if n == 0 {
				return "", false
			}
			off += n
			for i := uint64(0); i < ackRangeCount; i++ {
				_, n = readVarint(plaintext[off:])
				if n == 0 {
					return "", false
				}
				off += n
				_, n = readVarint(plaintext[off:])
				if n == 0 {
					return "", false
				}
				off += n
			}
			if frameType == 0x03 {
				for i := 0; i < 3; i++ {
					_, n = readVarint(plaintext[off:])
					if n == 0 {
						return "", false
					}
					off += n
				}
			}
		default:
			if frameType&0x08 != 0 {
				_, n := readVarint(plaintext[off:])
				if n == 0 {
					return "", false
				}
				off += n
				if frameType&0x04 != 0 {
					_, n = readVarint(plaintext[off:])
					if n == 0 {
						return "", false
					}
					off += n
				}
				var dataLen uint64
				if frameType&0x02 != 0 {
					dataLen, n = readVarint(plaintext[off:])
					if n == 0 {
						return "", false
					}
					off += n
				} else {
					dataLen = uint64(len(plaintext) - off)
				}
				if uint64(len(plaintext)-off) < dataLen {
					return "", false
				}
				off += int(dataLen)
			} else {
				return "", false
			}
		}
	}
	return "", false
}

// extractSNIFromClientHello parses a TLS ClientHello from either a TLS record
// or QUIC CRYPTO frame handshake bytes.
func extractSNIFromClientHello(data []byte) (string, bool) {
	if len(data) < 5 {
		return "", false
	}
	var hs []byte
	if data[0] == 0x16 {
		recordLen := binary.BigEndian.Uint16(data[3:5])
		if len(data) < 5+int(recordLen) {
			return "", false
		}
		hs = data[5 : 5+int(recordLen)]
	} else if data[0] == 0x01 {
		hs = data
	} else {
		return "", false
	}
	if len(hs) < 4 || hs[0] != 0x01 {
		return "", false
	}
	hello := hs[4:]
	if len(hello) < 34 {
		return "", false
	}
	off := 34
	if len(hello) < off+1 {
		return "", false
	}
	sessionIDLen := int(hello[off])
	off++
	if len(hello) < off+sessionIDLen+2 {
		return "", false
	}
	off += sessionIDLen
	csLen := binary.BigEndian.Uint16(hello[off : off+2])
	off += 2
	if len(hello) < off+int(csLen)+1 {
		return "", false
	}
	off += int(csLen)
	cmLen := int(hello[off])
	off++
	if len(hello) < off+cmLen+2 {
		return "", false
	}
	off += cmLen
	extLen := binary.BigEndian.Uint16(hello[off : off+2])
	off += 2
	if len(hello) < off+int(extLen) {
		return "", false
	}
	extensions := hello[off : off+int(extLen)]
	eo := 0
	for eo+4 <= len(extensions) {
		extType := binary.BigEndian.Uint16(extensions[eo : eo+2])
		extDataLen := binary.BigEndian.Uint16(extensions[eo+2 : eo+4])
		if eo+4+int(extDataLen) > len(extensions) {
			return "", false
		}
		extData := extensions[eo+4 : eo+4+int(extDataLen)]
		if extType == 0x0000 {
			if len(extData) < 2 {
				return "", false
			}
			sniListLen := binary.BigEndian.Uint16(extData[0:2])
			if int(sniListLen) > len(extData)-2 {
				return "", false
			}
			sniData := extData[2 : 2+sniListLen]
			if len(sniData) < 3 {
				return "", false
			}
			if sniData[0] != 0x00 {
				return "", false
			}
			sniLen := binary.BigEndian.Uint16(sniData[1:3])
			if int(sniLen) > len(sniData)-3 {
				return "", false
			}
			return string(sniData[3 : 3+sniLen]), true
		}
		eo += 4 + int(extDataLen)
	}
	return "", false
}
