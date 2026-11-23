// Package cloudhost sets up the user's own Linux server as an XDial line: it
// connects over SSH after the user confirms the host key, inspects the server
// read-only, shows the planned changes, and only after confirmation installs a
// separate Shadowsocks 2022 service that it can roll back. Credentials are held
// in memory for one session and never written to logs or configuration.
package cloudhost

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// Target is what the user typed in the app. Password and PrivateKey are used
// only to authenticate this session (and, for a password, to answer sudo).
type Target struct {
	Host               string `json:"host"`
	Port               int    `json:"port,omitempty"`
	User               string `json:"user"`
	Password           string `json:"password,omitempty"`
	PrivateKey         string `json:"private_key,omitempty"`
	Passphrase         string `json:"passphrase,omitempty"`
	HostKeyFingerprint string `json:"host_key_fingerprint,omitempty"`
}

// HostKey is shown to the user before any credential is sent.
type HostKey struct {
	Fingerprint string `json:"fingerprint"`
	Algorithm   string `json:"algorithm"`
	// File is where the same key lives on the server, for `ssh-keygen -lf`.
	File string `json:"file"`
}

const (
	dialTimeout    = 15 * time.Second
	maxOutputBytes = 1 << 20
)

func (t Target) address() (string, error) {
	host := strings.TrimSpace(t.Host)
	if host == "" || strings.ContainsAny(host, " /\\@\t\r\n") {
		return "", newError("invalid_host", "服务器地址无效", "The server address is not valid")
	}
	port := t.Port
	if port == 0 {
		port = 22
	}
	if port < 1 || port > 65535 {
		return "", newError("invalid_port", "SSH 端口无效", "The SSH port is not valid")
	}
	return net.JoinHostPort(strings.Trim(host, "[]"), strconv.Itoa(port)), nil
}

// Fingerprint uses the OpenSSH SHA256 form, the same text `ssh-keygen -lf` prints.
func Fingerprint(key ssh.PublicKey) string {
	sum := sha256.Sum256(key.Marshal())
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

var errHostKeyCaptured = errors.New("host key captured")

// hostKeyAlgorithms is the same for scanning and signing in, so both see the
// same key; ed25519 comes first because it is what users usually look up.
var hostKeyAlgorithms = []string{
	ssh.KeyAlgoED25519,
	ssh.KeyAlgoECDSA256, ssh.KeyAlgoECDSA384, ssh.KeyAlgoECDSA521,
	ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256,
}

// HostKeyFile names the file on the server whose fingerprint the user can compare.
func HostKeyFile(algorithm string) string {
	switch {
	case algorithm == ssh.KeyAlgoED25519:
		return "/etc/ssh/ssh_host_ed25519_key.pub"
	case strings.HasPrefix(algorithm, "ecdsa-"):
		return "/etc/ssh/ssh_host_ecdsa_key.pub"
	default:
		return "/etc/ssh/ssh_host_rsa_key.pub"
	}
}

// ScanHostKey completes only the key exchange and stops before authentication,
// so the user can compare the fingerprint before any credential leaves the device.
func ScanHostKey(ctx context.Context, target Target) (HostKey, error) {
	address, err := target.address()
	if err != nil {
		return HostKey{}, err
	}
	var captured HostKey
	config := &ssh.ClientConfig{
		User: "xdial-host-key-scan",
		Auth: nil,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			captured = HostKey{Fingerprint: Fingerprint(key), Algorithm: key.Type(), File: HostKeyFile(key.Type())}
			return errHostKeyCaptured
		},
		HostKeyAlgorithms: hostKeyAlgorithms,
		Timeout:           dialTimeout,
	}
	conn, err := dialContext(ctx, address)
	if err != nil {
		return HostKey{}, connectionError(err)
	}
	defer conn.Close()
	_, _, _, err = ssh.NewClientConn(conn, address, config)
	if captured.Fingerprint != "" {
		return captured, nil
	}
	return HostKey{}, connectionError(err)
}

func dialContext(ctx context.Context, address string) (net.Conn, error) {
	dialer := net.Dialer{Timeout: dialTimeout}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	} else {
		_ = conn.SetDeadline(time.Now().Add(dialTimeout))
	}
	return conn, nil
}

type privilege int

const (
	privilegeNone privilege = iota
	privilegeRoot
	privilegeSudoNoPassword
	privilegeSudoPassword
)

func (p privilege) String() string {
	switch p {
	case privilegeRoot:
		return "root"
	case privilegeSudoNoPassword:
		return "sudo"
	case privilegeSudoPassword:
		return "sudo-password"
	default:
		return "none"
	}
}

// Session is one authenticated SSH connection. It is not safe to reuse after Close.
type Session struct {
	client    *ssh.Client
	target    Target
	hostKey   HostKey
	privilege privilege
	facts     facts
	report    *Report

	mu     sync.Mutex
	closed bool
}

// Connect authenticates only if the server presents the fingerprint the user
// confirmed; a different key is refused before credentials are sent.
func Connect(ctx context.Context, target Target) (*Session, error) {
	address, err := target.address()
	if err != nil {
		return nil, err
	}
	expected := strings.TrimSpace(target.HostKeyFingerprint)
	if expected == "" {
		return nil, newError("host_key_unconfirmed", "请先确认服务器指纹", "Confirm the server fingerprint first")
	}
	if strings.TrimSpace(target.User) == "" {
		return nil, newError("invalid_user", "请填写登录用户名", "Enter the login user name")
	}
	auth, err := authMethods(target)
	if err != nil {
		return nil, err
	}
	var presented HostKey
	config := &ssh.ClientConfig{
		User: target.User,
		Auth: auth,
		HostKeyCallback: func(_ string, _ net.Addr, key ssh.PublicKey) error {
			presented = HostKey{Fingerprint: Fingerprint(key), Algorithm: key.Type(), File: HostKeyFile(key.Type())}
			if presented.Fingerprint != expected {
				return errHostKeyChanged
			}
			return nil
		},
		HostKeyAlgorithms: hostKeyAlgorithms,
		Timeout:           dialTimeout,
	}
	conn, err := dialContext(ctx, address)
	if err != nil {
		return nil, connectionError(err)
	}
	clientConn, channels, requests, err := ssh.NewClientConn(conn, address, config)
	if err != nil {
		conn.Close()
		if errors.Is(err, errHostKeyChanged) || (presented.Fingerprint != "" && presented.Fingerprint != expected) {
			return nil, newError("host_key_changed",
				"服务器指纹与确认的不一致，已停止连接。请核实服务器后重新确认指纹。",
				"The server fingerprint does not match the one you confirmed, so XDial stopped. Check the server and confirm its fingerprint again.")
		}
		return nil, authenticationError(err)
	}
	_ = conn.SetDeadline(time.Time{})
	session := &Session{client: ssh.NewClient(clientConn, channels, requests), target: target, hostKey: presented}
	return session, nil
}

var errHostKeyChanged = errors.New("host key changed")

func authMethods(target Target) ([]ssh.AuthMethod, error) {
	var methods []ssh.AuthMethod
	if key := strings.TrimSpace(target.PrivateKey); key != "" {
		var signer ssh.Signer
		var err error
		if target.Passphrase != "" {
			signer, err = ssh.ParsePrivateKeyWithPassphrase([]byte(key), []byte(target.Passphrase))
		} else {
			signer, err = ssh.ParsePrivateKey([]byte(key))
		}
		if err != nil {
			var missing *ssh.PassphraseMissingError
			if errors.As(err, &missing) {
				return nil, newError("key_passphrase_required", "这个私钥需要密码短语", "This private key needs its passphrase")
			}
			return nil, newError("invalid_private_key", "无法读取私钥，或密码短语不正确", "The private key could not be read, or the passphrase is wrong")
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}
	if target.Password != "" {
		password := target.Password
		methods = append(methods, ssh.Password(password),
			ssh.KeyboardInteractive(func(_, _ string, questions []string, _ []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = password
				}
				return answers, nil
			}))
	}
	if len(methods) == 0 {
		return nil, newError("credentials_required", "请填写密码或私钥", "Enter a password or a private key")
	}
	return methods, nil
}

// Close ends the connection; commands still running are interrupted.
func (s *Session) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	return s.client.Close()
}

// HostKey is the key this session verified.
func (s *Session) HostKey() HostKey { return s.hostKey }

type commandResult struct {
	stdout []byte
	stderr []byte
	code   int
}

// run executes one shell script as the login user. The script is built only
// from constants and validated values; user text never reaches the shell.
func (s *Session) run(ctx context.Context, script string, stdin []byte) (commandResult, error) {
	if err := ctx.Err(); err != nil {
		return commandResult{}, err
	}
	opened := make(chan struct{})
	stopOpening := s.interruptOnCancel(ctx, opened, nil)
	sshSession, err := s.client.NewSession()
	close(opened)
	stopOpening()
	if err != nil {
		if ctx.Err() != nil {
			return commandResult{}, ctx.Err()
		}
		return commandResult{}, newError("ssh_session_failed", "SSH 连接已断开", "The SSH connection was lost")
	}
	defer sshSession.Close()
	if err := ctx.Err(); err != nil {
		return commandResult{}, err
	}
	var stdout, stderr limitedBuffer
	stdout.limit, stderr.limit = maxOutputBytes, maxOutputBytes
	sshSession.Stdout = &stdout
	sshSession.Stderr = &stderr
	if stdin != nil {
		sshSession.Stdin = bytes.NewReader(stdin)
	}
	// Do not signal before exec has been acknowledged: a peer could otherwise
	// receive TERM before it starts the command and then run it uncancelled.
	started := make(chan struct{})
	stopStarting := s.interruptOnCancel(ctx, started, nil)
	err = sshSession.Start("sh -c " + shellQuote(script))
	close(started)
	stopStarting()
	if err == nil {
		finished := make(chan struct{})
		stopCommand := s.interruptOnCancel(ctx, finished, func() { _ = sshSession.Signal(ssh.SIGTERM) })
		err = sshSession.Wait()
		close(finished)
		stopCommand()
	}
	if ctx.Err() != nil {
		return commandResult{}, ctx.Err()
	}
	result := commandResult{stdout: stdout.Bytes(), stderr: stderr.Bytes()}
	if err != nil {
		var exit *ssh.ExitError
		if errors.As(err, &exit) {
			result.code = exit.ExitStatus()
			return result, nil
		}
		return result, newError("ssh_command_failed", "命令没有执行完，SSH 连接可能已断开", "A command did not finish; the SSH connection may have dropped")
	}
	return result, nil
}

// interruptOnCancel owns cancellation for both channel opening and command
// execution. Responsive commands receive TERM; only an unresponsive operation
// loses the transport. Joining both callbacks prevents a late close during undo.
const cancellationGrace = 2 * time.Second

func (s *Session) interruptOnCancel(ctx context.Context, finished <-chan struct{}, interrupt func()) func() {
	cancelFinished := make(chan struct{})
	stop := context.AfterFunc(ctx, func() {
		defer close(cancelFinished)
		forced := make(chan struct{})
		force := time.AfterFunc(cancellationGrace, func() {
			defer close(forced)
			_ = s.Close()
		})
		if interrupt != nil {
			interrupt()
		}
		<-finished
		if !force.Stop() {
			<-forced
		}
	})
	return func() {
		if !stop() {
			<-cancelFinished
		}
	}
}

// runPrivileged runs the script as root, answering sudo with the login password
// through stdin when that is the only way. Extra stdin follows the password line.
func (s *Session) runPrivileged(ctx context.Context, script string, stdin []byte) (commandResult, error) {
	switch s.privilege {
	case privilegeRoot:
		return s.run(ctx, script, stdin)
	case privilegeSudoNoPassword:
		return s.run(ctx, "sudo -n sh -c "+shellQuote(script), stdin)
	case privilegeSudoPassword:
		// Validate on a separate input stream; do not use -k with -v because that
		// would prevent updating the credential timestamp. Keep the same parent
		// shell for validation and execution: sudo's default
		// non-TTY timestamp belongs to the parent PID. A trailing command prevents
		// the shell from exec-optimising the second sudo into a different parent.
		input := append([]byte(s.target.Password+"\n"), stdin...)
		return s.run(ctx, "IFS= read -r password; printf '%s\n' \"$password\" | sudo -S -p '' -v && sudo -n sh -c "+shellQuote(script)+"; status=$?; exit \"$status\"", input)
	default:
		return commandResult{}, newError("no_privilege", "这个账号没有 root 或 sudo 权限", "This account has no root or sudo access")
	}
}

// detectPrivilege prefers root, then passwordless sudo, then sudo with the login password.
func (s *Session) detectPrivilege(ctx context.Context) error {
	result, err := s.run(ctx, "id -u", nil)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(result.stdout)) == "0" {
		s.privilege = privilegeRoot
		return nil
	}
	if result, err = s.run(ctx, "command -v sudo >/dev/null 2>&1 && sudo -n true", nil); err != nil {
		return err
	}
	if result.code == 0 {
		s.privilege = privilegeSudoNoPassword
		return nil
	}
	if s.target.Password != "" {
		result, err = s.run(ctx, "command -v sudo >/dev/null 2>&1 && sudo -S -p '' true", []byte(s.target.Password+"\n"))
		if err != nil {
			return err
		}
		if result.code == 0 {
			s.privilege = privilegeSudoPassword
			return nil
		}
	}
	s.privilege = privilegeNone
	return nil
}

type limitedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if remaining := b.limit - b.Len(); remaining > 0 {
		if len(p) > remaining {
			b.Buffer.Write(p[:remaining])
		} else {
			b.Buffer.Write(p)
		}
	}
	return len(p), nil
}

// shellQuote wraps a value in single quotes for POSIX sh.
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

func connectionError(err error) error {
	if err == nil {
		return newError("connect_failed", "无法连接服务器", "Could not connect to the server")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return newError("connect_timeout",
			"连接服务器超时。请确认地址和 SSH 端口，以及云服务商的安全组已放行这个端口。",
			"Connecting to the server timed out. Check the address and SSH port, and that the cloud provider's security group allows that port.")
	}
	if errors.Is(err, context.Canceled) {
		return newError("cancelled", "已取消", "Cancelled")
	}
	return newError("connect_failed",
		"无法连接服务器："+sanitizeNetworkError(err),
		"Could not connect to the server: "+sanitizeNetworkError(err))
}

func authenticationError(err error) error {
	if err != nil && strings.Contains(err.Error(), "unable to authenticate") {
		return newError("auth_failed", "用户名、密码或私钥不正确", "The user name, password or private key is not accepted")
	}
	return connectionError(err)
}

// sanitizeNetworkError keeps the reason without echoing anything the user typed.
func sanitizeNetworkError(err error) string {
	text := err.Error()
	switch {
	case strings.Contains(text, "connection refused"):
		return "连接被拒绝 (connection refused)"
	case strings.Contains(text, "no such host"):
		return "找不到这个地址 (no such host)"
	case strings.Contains(text, "network is unreachable"):
		return "网络不可达 (network unreachable)"
	case strings.Contains(text, "connection reset"):
		return "连接被重置 (connection reset)"
	case strings.Contains(text, "handshake") || strings.Contains(text, "EOF"):
		return "SSH 握手没有完成 (handshake failed)"
	default:
		return "网络错误 (network error)"
	}
}
