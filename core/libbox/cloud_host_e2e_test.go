//go:build cloudhost_e2e

// End-to-end test of "add my server" against an isolated container with real
// systemd, sshd and apt (see scripts/test-cloudhost-e2e.sh). It never touches a
// real cloud server.
package libbox

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"encoding/pem"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

type e2eReply struct {
	OK    bool            `json:"ok"`
	Data  json.RawMessage `json:"data"`
	Error *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func decodeReply(t *testing.T, raw string) e2eReply {
	t.Helper()
	var reply e2eReply
	if err := json.Unmarshal([]byte(raw), &reply); err != nil {
		t.Fatalf("reply %q: %v", raw, err)
	}
	return reply
}

func mustOK(t *testing.T, raw string, out interface{}) {
	t.Helper()
	reply := decodeReply(t, raw)
	if !reply.OK {
		t.Fatalf("expected success, got %s: %s", reply.Error.Code, reply.Error.Message)
	}
	if out != nil {
		if err := json.Unmarshal(reply.Data, out); err != nil {
			t.Fatal(err)
		}
	}
}

func mustFail(t *testing.T, raw, code string) {
	t.Helper()
	reply := decodeReply(t, raw)
	if reply.OK || reply.Error == nil || reply.Error.Code != code {
		t.Fatalf("expected error %s, got %s", code, raw)
	}
}

type e2eEnv struct {
	host      string
	sshPort   int
	password  string
	container string
	ports     [3]int
}

func loadE2E(t *testing.T) e2eEnv {
	host, port, err := net.SplitHostPort(os.Getenv("XDIAL_E2E_SSH_ADDR"))
	if err != nil {
		t.Skip("XDIAL_E2E_SSH_ADDR not set; run scripts/test-cloudhost-e2e.sh")
	}
	env := e2eEnv{host: host, password: os.Getenv("XDIAL_E2E_PASSWORD"), container: os.Getenv("XDIAL_E2E_CONTAINER")}
	env.sshPort, _ = strconv.Atoi(port)
	for i, name := range []string{"XDIAL_E2E_PORT_A", "XDIAL_E2E_PORT_B", "XDIAL_E2E_PORT_C"} {
		env.ports[i], _ = strconv.Atoi(os.Getenv(name))
	}
	return env
}

func (e e2eEnv) exec(t *testing.T, script string) (string, int) {
	t.Helper()
	cmd := exec.Command("docker", "exec", e.container, "sh", "-c", script)
	out, err := cmd.CombinedOutput()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("docker exec: %v", err)
	}
	return strings.TrimSpace(string(out)), code
}

func (e e2eEnv) target(user, fingerprint string) string {
	raw, _ := json.Marshal(map[string]interface{}{
		"host": e.host, "port": e.sshPort, "user": user, "password": e.password, "host_key_fingerprint": fingerprint,
	})
	return string(raw)
}

// assertClean checks that nothing XDial creates is left on the server.
func (e e2eEnv) assertClean(t *testing.T, stage string) {
	t.Helper()
	for _, check := range []string{
		"test ! -e /etc/xdial-proxy",
		"test ! -e /etc/systemd/system/xdial-proxy.service",
		"test ! -e /etc/apt/sources.list.d/xdial-sagernet.sources",
		"test ! -e /etc/apt/keyrings/xdial-sagernet.asc",
		"! dpkg -s sing-box >/dev/null 2>&1",
		"! systemctl is-active --quiet xdial-proxy",
	} {
		if out, code := e.exec(t, check); code != 0 {
			t.Errorf("%s: left behind (%s) %s", stage, check, out)
		}
	}
}

type recorder struct {
	mu      sync.Mutex
	events  []map[string]string
	onEvent func(map[string]string)
}

func (r *recorder) OnEvent(raw string) {
	var event map[string]string
	_ = json.Unmarshal([]byte(raw), &event)
	r.mu.Lock()
	r.events = append(r.events, event)
	hook := r.onEvent
	r.mu.Unlock()
	if hook != nil {
		hook(event)
	}
}

func TestCloudHostEndToEnd(t *testing.T) {
	env := loadE2E(t)
	setup := NewCloudHostSetup()
	defer setup.Close()

	var key struct{ Fingerprint string }
	mustOK(t, setup.ScanHostKey(env.target("deploy", "")), &key)
	if !strings.HasPrefix(key.Fingerprint, "SHA256:") {
		t.Fatalf("fingerprint %q", key.Fingerprint)
	}

	t.Run("refuses a different host key", func(t *testing.T) {
		mustFail(t, setup.ConnectAndInspect(env.target("deploy", "SHA256:"+strings.Repeat("A", 43))), "host_key_changed")
	})
	t.Run("does not run injected user names", func(t *testing.T) {
		mustFail(t, setup.ConnectAndInspect(env.target("deploy;touch /tmp/xdial-pwned", key.Fingerprint)), "auth_failed")
		if _, code := env.exec(t, "test ! -e /tmp/xdial-pwned"); code != 0 {
			t.Fatal("an injected user name ran on the server")
		}
	})
	t.Run("refuses accounts without sudo", func(t *testing.T) {
		var report struct{ Blocking []struct{ Code string } }
		mustOK(t, setup.ConnectAndInspect(env.target("plain", key.Fingerprint)), &report)
		if len(report.Blocking) == 0 || report.Blocking[0].Code != "no_privilege" {
			t.Fatalf("blocking = %+v", report.Blocking)
		}
		mustFail(t, setup.Plan(env.ports[0]), "blocked")
	})

	var report struct {
		Privilege     string
		SuggestedPort int `json:"suggested_port"`
		Blocking      []struct{ Code string }
	}
	mustOK(t, setup.ConnectAndInspect(env.target("deploy", key.Fingerprint)), &report)
	if report.Privilege != "sudo-password" || len(report.Blocking) != 0 {
		t.Fatalf("report = %+v", report)
	}
	if _, code := env.exec(t, "test ! -e /tmp/xdial-pwned-password"); code != 0 {
		t.Fatal("the sudo password was executed by a shell")
	}
	mustFail(t, setup.Plan(22), "port_in_use")
	env.assertClean(t, "after inspection")

	t.Run("rolls back a failed setup", func(t *testing.T) {
		// Occupy the port after inspection so the service cannot start.
		port := strconv.Itoa(env.ports[2])
		exec.Command("docker", "exec", "-d", env.container, "nc", "-lk", port).Run()
		defer env.exec(t, "pkill -x nc || true")
		for i := 0; i < 20; i++ {
			if _, code := env.exec(t, "ss -Hltn 'sport = :"+port+"' | grep -q ."); code == 0 {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		events := &recorder{}
		mustFail(t, setup.Deploy(env.ports[2], events), "service_not_listening")
		env.assertClean(t, "after failed setup")
		var rolledBack bool
		for _, event := range events.events {
			if event["status"] == "rolled_back" && event["step"] == "install" {
				rolledBack = true
			}
		}
		if !rolledBack {
			t.Fatalf("the package installed by this run was not removed: %+v", events.events)
		}
	})

	t.Run("cancelling rolls back", func(t *testing.T) {
		events := &recorder{}
		events.onEvent = func(event map[string]string) {
			if event["step"] == "config" && event["status"] == "done" {
				go setup.Cancel()
			}
		}
		mustFail(t, setup.Deploy(env.ports[0], events), "cancelled")
		env.assertClean(t, "after cancel")
	})

	t.Run("recovers after the connection drops mid-way", func(t *testing.T) {
		mustOK(t, setup.ConnectAndInspect(env.target("deploy", key.Fingerprint)), nil)
		events := &recorder{}
		events.onEvent = func(event map[string]string) {
			if event["step"] == "unit" && event["status"] == "done" {
				// Drop this SSH session the way a lost network or a killed app would.
				exec.Command("docker", "exec", env.container, "pkill", "-KILL", "-u", "deploy").Run()
			}
		}
		mustFail(t, setup.Deploy(env.ports[2], events), "undo_incomplete")
		if out, code := env.exec(t, "grep -q '\"in_progress\":true' /etc/xdial-proxy/state.json && test -e /etc/systemd/system/xdial-proxy.service"); code != 0 {
			t.Fatalf("the server must keep a record of the unfinished run: %s", out)
		}

		recovery := NewCloudHostSetup()
		defer recovery.Close()
		var report struct {
			Interrupted bool
			Blocking    []struct{ Code string }
		}
		mustOK(t, recovery.ConnectAndInspect(env.target("deploy", key.Fingerprint)), &report)
		if !report.Interrupted || len(report.Blocking) != 0 {
			t.Fatalf("report = %+v", report)
		}
		var plan struct {
			Steps []struct{ ID string }
		}
		mustOK(t, recovery.Plan(env.ports[2]), &plan)
		if len(plan.Steps) == 0 || plan.Steps[0].ID != "recover" {
			t.Fatalf("plan = %+v", plan.Steps)
		}
		var recovered struct{ Port int }
		mustOK(t, recovery.Deploy(env.ports[2], &recorder{}), &recovered)
		if out, code := env.exec(t, "systemctl is-active xdial-proxy && ! grep -q in_progress /etc/xdial-proxy/state.json"); code != 0 {
			t.Fatalf("after recovery: %s", out)
		}
	})

	var result struct {
		Server, Method, Password string
		Port                     int
		Reused                   bool
	}
	t.Run("sets up the proxy", func(t *testing.T) {
		mustOK(t, setup.ConnectAndInspect(env.target("deploy", key.Fingerprint)), nil)
		mustOK(t, setup.Deploy(env.ports[0], &recorder{}), &result)
		if result.Port != env.ports[0] || result.Method != "2022-blake3-aes-128-gcm" || len(result.Password) != 24 || result.Reused {
			t.Fatalf("result = %+v", result)
		}
		if out, code := env.exec(t, "systemctl is-active xdial-proxy && systemctl is-enabled --quiet xdial-proxy && stat -c %a /etc/xdial-proxy/config.json && ! systemctl is-enabled --quiet sing-box"); code != 0 {
			t.Fatalf("service state: %s", out)
		}
		if out, _ := env.exec(t, "journalctl -u xdial-proxy --no-pager | grep -c '"+result.Password+"' || true"); out != "0" {
			t.Fatal("the proxy key appeared in the service log")
		}
	})

	t.Run("failed move preserves a disabled service", func(t *testing.T) {
		if out, code := env.exec(t, "systemctl disable --now xdial-proxy"); code != 0 {
			t.Fatalf("disable: %s", out)
		}
		defer func() {
			if out, code := env.exec(t, "systemctl daemon-reload && systemctl enable --now xdial-proxy"); code != 0 {
				t.Fatalf("restore fixture: %s", out)
			}
			for i := 0; i < 20; i++ {
				if _, code := env.exec(t, "systemctl is-active --quiet xdial-proxy && ss -Hltn 'sport = :"+strconv.Itoa(result.Port)+"' | grep -q ."); code == 0 {
					return
				}
				time.Sleep(250 * time.Millisecond)
			}
			t.Fatal("restored fixture did not start listening")
		}()
		again := NewCloudHostSetup()
		defer again.Close()
		mustOK(t, again.ConnectAndInspect(env.target("deploy", key.Fingerprint)), nil)
		port := strconv.Itoa(env.ports[1])
		exec.Command("docker", "exec", "-d", env.container, "nc", "-lk", port).Run()
		defer env.exec(t, "pkill -x nc || true")
		for i := 0; i < 20; i++ {
			if _, code := env.exec(t, "ss -Hltn 'sport = :"+port+"' | grep -q ."); code == 0 {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		mustFail(t, again.Deploy(env.ports[1], &recorder{}), "service_not_listening")
		if out, code := env.exec(t, "test \"$(systemctl is-enabled xdial-proxy)\" = disabled && ! systemctl is-active --quiet xdial-proxy && ! grep -q in_progress /etc/xdial-proxy/state.json"); code != 0 {
			t.Fatalf("boot policy changed after rollback: %s", out)
		}
	})

	t.Run("traffic flows through the proxy", func(t *testing.T) {
		line, _ := json.Marshal(map[string]interface{}{
			"id": "cloud", "name": "My server", "type": "shadowsocks", "enabled": true,
			"ss_server": env.host, "ss_port": result.Port, "ss_method": result.Method, "ss_password": result.Password,
		})
		var measured lineThroughput
		mustOK(t, ProbeStandaloneLineThroughput(string(line), 45000), &measured)
		if measured.LatencyMS <= 0 || measured.DownloadBytes == 0 || measured.Mbps <= 0 || measured.ExitIP == "" {
			t.Fatalf("measurement = %+v", measured)
		}
		t.Logf("latency %d ms, %.1f Mbps, exit %s", measured.LatencyMS, measured.Mbps, measured.ExitIP)

		wrong, _ := json.Marshal(map[string]interface{}{
			"id": "cloud", "type": "shadowsocks", "enabled": true,
			"ss_server": env.host, "ss_port": result.Port, "ss_method": result.Method, "ss_password": "AAAAAAAAAAAAAAAAAAAAAA==",
		})
		mustFail(t, ProbeStandaloneLineThroughput(string(wrong), 15000), "proxy_unreachable")
	})

	t.Run("a second run reuses the proxy", func(t *testing.T) {
		again := NewCloudHostSetup()
		defer again.Close()
		var second struct {
			Existing *struct{ Port int }
		}
		mustOK(t, again.ConnectAndInspect(env.target("nopass", key.Fingerprint)), &second)
		if second.Existing == nil || second.Existing.Port != result.Port {
			t.Fatalf("existing = %+v", second.Existing)
		}
		var plan struct {
			Reuse bool
			Steps []struct{ ID string }
		}
		mustOK(t, again.Plan(0), &plan)
		if !plan.Reuse || len(plan.Steps) != 0 {
			t.Fatalf("plan = %+v", plan)
		}
		var reused struct {
			Password string
			Reused   bool
		}
		mustOK(t, again.Deploy(0, &recorder{}), &reused)
		if !reused.Reused || reused.Password != result.Password {
			t.Fatal("a second run must return the same proxy, not a new one")
		}
	})

	t.Run("moves to another port", func(t *testing.T) {
		mustOK(t, setup.ConnectAndInspect(env.target("deploy", key.Fingerprint)), nil)
		var moved struct {
			Port     int
			Password string
		}
		mustOK(t, setup.Deploy(env.ports[1], &recorder{}), &moved)
		if moved.Port != env.ports[1] || moved.Password == result.Password {
			t.Fatalf("moved = %+v", moved)
		}
		if out, code := env.exec(t, "ss -Hltn 'sport = :"+strconv.Itoa(env.ports[1])+"' | grep -q . && ! ss -Hltn 'sport = :"+strconv.Itoa(env.ports[0])+"' | grep -q ."); code != 0 {
			t.Fatalf("listening: %s", out)
		}
	})

	t.Run("root signs in with a private key", func(t *testing.T) {
		_, private, _ := ed25519.GenerateKey(rand.Reader)
		block, _ := ssh.MarshalPrivateKey(private, "")
		signer, _ := ssh.NewSignerFromKey(private)
		env.exec(t, "echo '"+strings.TrimSpace(string(ssh.MarshalAuthorizedKey(signer.PublicKey())))+"' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys")
		target, _ := json.Marshal(map[string]interface{}{
			"host": env.host, "port": env.sshPort, "user": "root", "private_key": string(pem.EncodeToMemory(block)), "host_key_fingerprint": key.Fingerprint,
		})
		root := NewCloudHostSetup()
		defer root.Close()
		var rootReport struct{ Privilege string }
		mustOK(t, root.ConnectAndInspect(string(target)), &rootReport)
		if rootReport.Privilege != "root" {
			t.Fatalf("privilege = %s", rootReport.Privilege)
		}
	})

	t.Run("notices a replaced host key", func(t *testing.T) {
		env.exec(t, "rm -f /etc/ssh/ssh_host_* && ssh-keygen -A >/dev/null && systemctl restart ssh")
		time.Sleep(time.Second)
		mustFail(t, setup.ConnectAndInspect(env.target("deploy", key.Fingerprint)), "host_key_changed")
	})
}
