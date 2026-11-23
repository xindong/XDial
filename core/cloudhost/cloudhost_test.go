package cloudhost

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func ubuntuFacts() facts {
	return facts{
		"os_id": "ubuntu", "os_version": "24.04", "os_name": "Ubuntu 24.04.1 LTS",
		"arch": "x86_64", "pid1": "systemd", "uid": "0", "systemctl": "/usr/bin/systemctl",
		"apt": "/usr/bin/apt-get", "disk_kb": "5000000",
		"listening": "0.0.0.0:22 [::]:22 127.0.0.53%lo:53 0.0.0.0:68",
	}
}

func codes(issues []Issue) []string {
	var result []string
	for _, i := range issues {
		result = append(result, i.Code)
	}
	return result
}

func TestEvaluateAcceptsSupportedSystemsOnly(t *testing.T) {
	cases := []struct {
		id, version, arch string
		ok                bool
	}{
		{"ubuntu", "20.04", "x86_64", true},
		{"ubuntu", "24.04", "aarch64", true},
		{"ubuntu", "18.04", "x86_64", false},
		{"debian", "11", "x86_64", false},
		{"debian", "12", "aarch64", true},
		{"debian", "10", "x86_64", false},
		{"centos", "9", "x86_64", false},
		{"ubuntu", "24.04", "armv7l", false},
	}
	for _, c := range cases {
		f := ubuntuFacts()
		f["os_id"], f["os_version"], f["arch"] = c.id, c.version, c.arch
		report := evaluate(f, privilegeRoot)
		if got := len(report.Blocking) == 0; got != c.ok {
			t.Errorf("%s %s %s: supported=%v, blocking %v", c.id, c.version, c.arch, got, codes(report.Blocking))
		}
	}
}

func TestEvaluateBlocksWithoutSystemdOrPrivilege(t *testing.T) {
	f := ubuntuFacts()
	f["pid1"] = "bash"
	if report := evaluate(f, privilegeRoot); !contains(codes(report.Blocking), "no_systemd") {
		t.Fatalf("a container without systemd must be refused: %v", codes(report.Blocking))
	}
	if report := evaluate(ubuntuFacts(), privilegeNone); !contains(codes(report.Blocking), "no_privilege") {
		t.Fatalf("an account without root or sudo must be refused: %v", codes(report.Blocking))
	}
}

func TestEvaluateNeverTakesOverExistingServices(t *testing.T) {
	f := ubuntuFacts()
	f["singbox_path"] = "/usr/local/bin/sing-box"
	f["singbox_service"] = "active"
	f["ufw"] = "Status: active"
	report := evaluate(f, privilegeRoot)
	if len(report.Blocking) != 0 {
		t.Fatalf("unexpected blocking: %v", codes(report.Blocking))
	}
	for _, code := range []string{"sing_box_manual", "sing_box_service", "ufw_active", "security_group"} {
		if !contains(codes(report.Notes), code) {
			t.Errorf("missing note %s: %v", code, codes(report.Notes))
		}
	}
	plan, err := BuildPlan(report, f, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, step := range plan.Steps {
		if step.ID == "install" || step.ID == "apt_source" || step.ID == "apt_key" {
			t.Fatalf("an existing sing-box must be reused, not reinstalled: %+v", plan.Steps)
		}
	}
	if plan.binary != "/usr/local/bin/sing-box" {
		t.Fatalf("binary = %q", plan.binary)
	}

	f["xdial_unit"] = "yes"
	if report := evaluate(f, privilegeRoot); !contains(codes(report.Blocking), "foreign_xdial_service") {
		t.Fatalf("an xdial-proxy unit XDial cannot read must not be overwritten: %v", codes(report.Blocking))
	}
	f["xdial_unit"] = ""
	f["singbox_path"] = "/opt/sing box/sing-box"
	if report := evaluate(f, privilegeRoot); !contains(codes(report.Blocking), "unusable_sing_box") {
		t.Fatalf("an unsafe binary path must not reach the unit file: %v", codes(report.Blocking))
	}
}

func TestPlanForFreshServerInstallsFromSignedRepository(t *testing.T) {
	f := ubuntuFacts()
	report := evaluate(f, privilegeSudoPassword)
	plan, err := BuildPlan(report, f, 0)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, step := range plan.Steps {
		ids = append(ids, step.ID)
	}
	if got := strings.Join(ids, ","); got != "apt_key,apt_source,install,config,unit,start" {
		t.Fatalf("steps = %s", got)
	}
	if plan.Port < portRangeLow || plan.Port > portRangeHigh || !report.PortAvailable(plan.Port) {
		t.Fatalf("suggested port %d", plan.Port)
	}

	f["sagernet_sources"] = "/etc/apt/sources.list.d/sagernet.sources"
	report = evaluate(f, privilegeRoot)
	plan, _ = BuildPlan(report, f, 0)
	if plan.Steps[0].ID != "install" || plan.source != "/etc/apt/sources.list.d/sagernet.sources" {
		t.Fatalf("an existing sing-box repository must be reused: %+v %q", plan.Steps, plan.source)
	}
}

func TestPlanRefusesOccupiedOrPrivilegedPorts(t *testing.T) {
	f := ubuntuFacts()
	report := evaluate(f, privilegeRoot)
	for _, port := range []int{22, 68, 80, 1023, 70000} {
		if _, err := BuildPlan(report, f, port); err == nil || AsError(err).Code != "port_in_use" {
			t.Errorf("port %d: %v", port, err)
		}
	}
	if _, err := BuildPlan(report, f, 30000); err != nil {
		t.Fatalf("free port refused: %v", err)
	}
}

func TestPlanReusesAnEarlierDeployment(t *testing.T) {
	config, _ := serverConfigJSON(31000, "AAAAAAAAAAAAAAAAAAAAAA==")
	f := ubuntuFacts()
	f["singbox_path"] = "/usr/bin/sing-box"
	f["dpkg_singbox"] = "install ok installed|1.12.0"
	f["xdial_config"] = base64.StdEncoding.EncodeToString(config)
	f["xdial_service"] = "active"
	f["listening"] += " 0.0.0.0:31000 [::]:31000"
	report := evaluate(f, privilegeRoot)
	if report.Existing == nil || report.Existing.Port != 31000 || report.SuggestedPort != 31000 {
		t.Fatalf("existing = %+v suggested %d", report.Existing, report.SuggestedPort)
	}
	plan, err := BuildPlan(report, f, 0)
	if err != nil || !plan.Reuse || len(plan.Steps) != 0 {
		t.Fatalf("a running deployment needs no changes: %+v %v", plan, err)
	}
	if raw, _ := json.Marshal(report); strings.Contains(string(raw), "AAAAAAAAAAAAAAAAAAAAAA==") {
		t.Fatal("the report must not carry the proxy key")
	}
	f["xdial_service"] = "inactive"
	plan, _ = BuildPlan(evaluate(f, privilegeRoot), f, 0)
	if len(plan.Steps) != 1 || plan.Steps[0].ID != "start" {
		t.Fatalf("a stopped deployment is only restarted: %+v", plan.Steps)
	}
	plan, err = BuildPlan(evaluate(f, privilegeRoot), f, 32000)
	if err != nil || plan.Reuse || plan.Steps[0].ID != "config" {
		t.Fatalf("moving to another port rewrites only the configuration: %+v %v", plan, err)
	}
}

func TestInterruptedSetupIsUndoneBeforeContinuing(t *testing.T) {
	interrupted, _ := json.Marshal(state{Version: 1, InProgress: true, InstalledPackage: true, AddedSource: true,
		Created: []string{"config_dir", "apt_key", "apt_source", "package", "config", "unit"}})
	f := ubuntuFacts()
	f["xdial_state"] = base64.StdEncoding.EncodeToString(interrupted)
	f["xdial_unit"] = "yes"
	f["singbox_path"] = "/usr/bin/sing-box"
	f["dpkg_singbox"] = "install ok installed|1.14.4"
	f["sagernet_sources"] = aptSourcePath
	report := evaluate(f, privilegeRoot)
	if !report.Interrupted || len(report.Blocking) != 0 || !contains(codes(report.Notes), "interrupted") {
		t.Fatalf("an interrupted XDial setup is recoverable, not foreign: %+v %v", report.Interrupted, codes(report.Blocking))
	}
	plan, err := BuildPlan(report, f, 0)
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, step := range plan.Steps {
		ids = append(ids, step.ID)
	}
	// The package and repository it added are removed first, so they are set up again.
	if got := strings.Join(ids, ","); got != "recover,apt_key,apt_source,install,config,unit,start" || !plan.Recover {
		t.Fatalf("steps = %s", got)
	}
}

func TestServerConfigAndKey(t *testing.T) {
	key, err := newShadowsocksKey()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(key)
	if err != nil || len(raw) != 16 {
		t.Fatalf("2022-blake3-aes-128-gcm needs a 16-byte key: %d %v", len(raw), err)
	}
	config, _ := serverConfigJSON(40000, key)
	existing := parseExisting(base64.StdEncoding.EncodeToString(config))
	if existing == nil || existing.Port != 40000 || existing.Method != shadowsocksKey || existing.Password != key {
		t.Fatalf("round trip: %+v", existing)
	}
	if !strings.Contains(unitFile("/usr/bin/sing-box"), "ExecStart=/usr/bin/sing-box run -c /etc/xdial-proxy/config.json") {
		t.Fatal("unit file")
	}
}

func TestEmbeddedRepositoryKeyIsTheProjectKey(t *testing.T) {
	sum := sha256.Sum256(sagernetKey)
	if got := hex.EncodeToString(sum[:]); got != "803d5a2f09fe9d360008161aa2684e7f49a211d48a4116d0651b08bdd90bdea1" {
		t.Fatalf("sagernet.asc changed: %s", got)
	}
}

func TestParseListeningPorts(t *testing.T) {
	got := parseListeningPorts("0.0.0.0:22 [::]:22 127.0.0.53%lo:53 *:8080 garbage")
	if fmt.Sprint(got) != "[22 53 8080]" {
		t.Fatalf("ports = %v", got)
	}
}

func TestShellQuoteKeepsValuesLiteral(t *testing.T) {
	if got := shellQuote(`a'b; rm -rf / $(id)`); got != `'a'\''b; rm -rf / $(id)'` {
		t.Fatalf("quote = %s", got)
	}
}

// testServer is a minimal in-process SSH server that records commands and stdin.
type testServer struct {
	listener      net.Listener
	key           ssh.Signer
	user          string
	password      string
	mu            sync.Mutex
	commands      []string
	stdin         []string
	respond       func(string, string) (string, int)
	holdChannels  bool
	handleChannel func(ssh.Channel, <-chan *ssh.Request)
}

func newTestServer(t *testing.T, user, password string) *testServer {
	t.Helper()
	_, private, _ := ed25519.GenerateKey(rand.Reader)
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &testServer{listener: listener, key: signer, user: user, password: password}
	t.Cleanup(func() { listener.Close() })
	go server.serve()
	return server
}

func (s *testServer) port() int {
	_, port, _ := net.SplitHostPort(s.listener.Addr().String())
	n, _ := strconv.Atoi(port)
	return n
}

func (s *testServer) serve() {
	config := &ssh.ServerConfig{
		PasswordCallback: func(meta ssh.ConnMetadata, password []byte) (*ssh.Permissions, error) {
			if meta.User() == s.user && string(password) == s.password {
				return nil, nil
			}
			return nil, fmt.Errorf("denied")
		},
	}
	config.AddHostKey(s.key)
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		go func() {
			_, channels, requests, err := ssh.NewServerConn(conn, config)
			if err != nil {
				conn.Close()
				return
			}
			go ssh.DiscardRequests(requests)
			for newChannel := range channels {
				if s.holdChannels {
					continue
				}
				channel, channelRequests, err := newChannel.Accept()
				if err != nil {
					continue
				}
				if s.handleChannel != nil {
					go s.handleChannel(channel, channelRequests)
				} else {
					go s.handle(channel, channelRequests)
				}
			}
		}()
	}
}

func (s *testServer) handle(channel ssh.Channel, requests <-chan *ssh.Request) {
	defer channel.Close()
	for request := range requests {
		if request.Type != "exec" {
			request.Reply(false, nil)
			continue
		}
		var payload struct{ Command string }
		ssh.Unmarshal(request.Payload, &payload)
		request.Reply(true, nil)
		input, _ := io.ReadAll(channel)
		s.mu.Lock()
		s.commands = append(s.commands, payload.Command)
		s.stdin = append(s.stdin, string(input))
		s.mu.Unlock()
		status := 0
		if strings.Contains(payload.Command, "id -u") {
			channel.Write([]byte("1000\n"))
		}
		if strings.Contains(payload.Command, "sudo -n true") {
			status = 1
		}
		if s.respond != nil {
			output, code := s.respond(payload.Command, string(input))
			status = code
			channel.Write([]byte(output))
		}
		channel.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(status)}))
		return
	}
}

func TestHostKeyIsConfirmedBeforeCredentialsAreSent(t *testing.T) {
	server := newTestServer(t, "deploy", `p'w;$(touch /tmp/x)`)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	target := Target{Host: "127.0.0.1", Port: server.port(), User: "deploy", Password: `p'w;$(touch /tmp/x)`}

	if _, err := Connect(ctx, target); err == nil || AsError(err).Code != "host_key_unconfirmed" {
		t.Fatalf("connecting without a confirmed fingerprint: %v", err)
	}
	key, err := ScanHostKey(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	if key.Fingerprint != Fingerprint(server.key.PublicKey()) || key.Algorithm != "ssh-ed25519" {
		t.Fatalf("scanned %+v", key)
	}

	target.HostKeyFingerprint = "SHA256:" + strings.Repeat("A", 43)
	if _, err := Connect(ctx, target); err == nil || AsError(err).Code != "host_key_changed" {
		t.Fatalf("a different host key must be refused: %v", err)
	}

	target.HostKeyFingerprint = key.Fingerprint
	wrong := target
	wrong.Password = "nope"
	if _, err := Connect(ctx, wrong); err == nil || AsError(err).Code != "auth_failed" {
		t.Fatalf("wrong password: %v", err)
	}

	session, err := Connect(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	defer session.Close()
	if err := session.detectPrivilege(ctx); err != nil {
		t.Fatal(err)
	}
	if session.privilege != privilegeSudoPassword {
		t.Fatalf("privilege %v", session.privilege)
	}
	// The password reaches sudo through stdin only; it never appears in a command line.
	server.mu.Lock()
	defer server.mu.Unlock()
	for _, command := range server.commands {
		if strings.Contains(command, "touch /tmp/x") || strings.Contains(command, "p'w") {
			t.Fatalf("the password leaked into a command: %q", command)
		}
	}
	if last := server.stdin[len(server.stdin)-1]; last != target.Password+"\n" {
		t.Fatalf("sudo stdin = %q", last)
	}
}

func TestScanTimesOutOnSilentPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			defer conn.Close()
		}
	}()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	n, _ := strconv.Atoi(port)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if _, err := ScanHostKey(ctx, Target{Host: "127.0.0.1", Port: n}); err == nil {
		t.Fatal("a port that never speaks SSH must fail")
	}
}

func TestHostKeyFileMatchesTheAlgorithm(t *testing.T) {
	for algorithm, file := range map[string]string{
		"ssh-ed25519":         "/etc/ssh/ssh_host_ed25519_key.pub",
		"ecdsa-sha2-nistp256": "/etc/ssh/ssh_host_ecdsa_key.pub",
		"rsa-sha2-512":        "/etc/ssh/ssh_host_rsa_key.pub",
	} {
		if got := HostKeyFile(algorithm); got != file {
			t.Errorf("%s: %s", algorithm, got)
		}
	}
	if hostKeyAlgorithms[0] != ssh.KeyAlgoED25519 {
		t.Fatal("ed25519 must be preferred, matching the key users usually check")
	}
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}
