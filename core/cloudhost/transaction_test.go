package cloudhost

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

func deploymentSession(t *testing.T, server *testServer) *Session {
	t.Helper()
	s, err := Connect(context.Background(), Target{Host: "127.0.0.1", Port: server.port(), User: server.user, Password: server.password, HostKeyFingerprint: Fingerprint(server.key.PublicKey())})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	s.privilege = privilegeRoot
	return s
}

func TestMoveFailureRestoresConfigAndKeepsJournalOnUndoFailure(t *testing.T) {
	for _, undoFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "undo succeeds", true: "undo fails"}[undoFails], func(t *testing.T) {
			server := newTestServer(t, "root", "secret")
			var journal state
			restored := false
			server.respond = func(cmd, input string) (string, int) {
				if strings.Contains(cmd, statePath+".xdial-tmp") && input != "" {
					journal = state{}
					if err := json.Unmarshal([]byte(input), &journal); err != nil {
						t.Error(err)
					}
				}
				if strings.Contains(cmd, " check -c ") {
					if !journal.InProgress || !journal.created("config_moved") || journal.Baseline == nil {
						t.Error("config changed without durable rollback intent")
					}
					return "", 1
				}
				if strings.Contains(cmd, "cp -p "+configPath+".previous ") {
					restored = true
					if undoFails {
						return "", 1
					}
				}
				if strings.Contains(cmd, "rm -rf "+configDir) || strings.Contains(cmd, "rm -f "+unitPath) {
					t.Error("existing resources must survive")
				}
				return "", 0
			}
			s := deploymentSession(t, server)
			f := ubuntuFacts()
			f["singbox_path"] = "/usr/bin/sing-box"
			config, _ := serverConfigJSON(31000, "AAAAAAAAAAAAAAAAAAAAAA==")
			f["xdial_config"] = encodeTestConfig(config)
			f["xdial_service"] = "active"
			s.facts = f
			r := evaluate(f, privilegeRoot)
			s.report = &r
			_, err := s.Deploy(context.Background(), 32000, nil)
			if err == nil || !restored {
				t.Fatalf("err %v restored %v", err, restored)
			}
			if undoFails && (!journal.InProgress || AsError(err).Code != "undo_incomplete") {
				t.Fatal("failed compensation erased journal")
			}
			if !undoFails && journal.InProgress {
				t.Fatal("successful rollback left dirty state")
			}
		})
	}
}

func TestFailedJournalPreventsMutation(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	changed := false
	server.respond = func(cmd, input string) (string, int) {
		if strings.Contains(cmd, statePath+".xdial-tmp") && input != "" {
			return "", 1
		}
		if strings.Contains(cmd, "apt-get install") || strings.Contains(cmd, aptKeyPath+".xdial-tmp") {
			changed = true
		}
		return "", 0
	}
	s := deploymentSession(t, server)
	s.facts = ubuntuFacts()
	r := evaluate(s.facts, privilegeRoot)
	s.report = &r
	if _, err := s.Deploy(context.Background(), 32000, nil); err == nil || changed {
		t.Fatalf("err=%v changed=%v", err, changed)
	}
}

func TestRollbackStopsBeforeRemovingRecoveryRecord(t *testing.T) {
	removed := false
	s := &Session{}
	if s.rollback(context.Background(), []undo{{step: "directory", run: func(context.Context) error { removed = true; return nil }}, {step: "package", run: func(context.Context) error { return errors.New("apt locked") }}}, func(Event) {}) || removed {
		t.Fatal("rollback must retain journal after failure")
	}
}

func TestCancellationUnblocksChannelOpening(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	server.holdChannels = true
	s := deploymentSession(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := s.run(ctx, "true", nil); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected cancellation")
		}
	case <-time.After(cancellationGrace + time.Second):
		t.Fatal("channel open ignored cancellation")
	}
}

func encodeTestConfig(raw []byte) string { return base64.StdEncoding.EncodeToString(raw) }

func TestSudoCachedAuthenticationCannotPrefixFileWithPassword(t *testing.T) {
	server := newTestServer(t, "deploy", "password")
	s := deploymentSession(t, server)
	s.privilege = privilegeSudoPassword
	if _, err := s.runPrivileged(context.Background(), "cat", []byte("file contents")); err != nil {
		t.Fatal(err)
	}
	server.mu.Lock()
	command := server.commands[len(server.commands)-1]
	input := server.stdin[len(server.stdin)-1]
	server.mu.Unlock()
	dir := t.TempDir()
	// Simulate sudo accepting cached credentials without reading its stdin.
	if err := os.WriteFile(filepath.Join(dir, "sudo"), []byte("#!/bin/sh\nif [ \"$1\" = -S ]; then printf '%s' \"$PPID\" > \"$XDIAL_TEST_AUTH_FILE\"; exit 0; fi\n[ \"$(cat \"$XDIAL_TEST_AUTH_FILE\")\" = \"$PPID\" ] || exit 88\nshift; exec \"$@\"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sh", "-c", command)
	cmd.Env = append(os.Environ(), "PATH="+dir+":"+os.Getenv("PATH"), "XDIAL_TEST_AUTH_FILE="+filepath.Join(dir, "auth"))
	cmd.Stdin = strings.NewReader(input)
	output, err := cmd.CombinedOutput()
	if err != nil || string(output) != "file contents" {
		t.Fatalf("output %q err %v", output, err)
	}
}

func TestRecoveryReinspectsExistingProxyBeforeDeploy(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	baseline := state{Version: 1, CreatedAt: 10}
	interrupted := state{Version: 1, InProgress: true, Created: []string{"config_moved"}, Baseline: &baseline, WasActive: true}
	f := ubuntuFacts()
	f["singbox_path"] = "/usr/bin/sing-box"
	raw, _ := json.Marshal(interrupted)
	f["xdial_state"] = encodeTestConfig(raw)
	inspected := false
	server.respond = func(cmd, input string) (string, int) {
		if strings.Contains(cmd, "id -u") && !strings.Contains(cmd, "emit os_id") {
			return "0\n", 0
		}
		if strings.Contains(cmd, "emit os_id") {
			inspected = true
			restored := ubuntuFacts()
			restored["singbox_path"] = "/usr/bin/sing-box"
			config, _ := serverConfigJSON(31000, "AAAAAAAAAAAAAAAAAAAAAA==")
			restored["xdial_config"] = encodeTestConfig(config)
			restored["xdial_service"] = "active"
			old, _ := json.Marshal(baseline)
			restored["xdial_state"] = encodeTestConfig(old)
			var output strings.Builder
			for k, v := range restored {
				output.WriteString(k + "=" + v + "\n")
			}
			return output.String(), 0
		}
		if strings.Contains(cmd, unitPath+".xdial-tmp") {
			t.Error("recovery treated original service as fresh")
		}
		if strings.Contains(cmd, " check -c ") {
			return "", 1
		}
		return "", 0
	}
	s := deploymentSession(t, server)
	s.facts = f
	r := evaluate(f, privilegeRoot)
	s.report = &r
	if _, err := s.Deploy(context.Background(), 32000, nil); err == nil || !inspected {
		t.Fatalf("err=%v inspected=%v", err, inspected)
	}
}

func TestUFWPartialFailureNeverRemovesPreexistingRule(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	udpAdded := false
	deletedUDP := false
	server.respond = func(cmd, input string) (string, int) {
		if strings.Contains(cmd, "ufw show added") {
			out := "ufw allow 32000/tcp\n"
			if udpAdded {
				out += "ufw allow 32000/udp comment xdial-proxy\n"
			}
			return out, 0
		}
		if strings.Contains(cmd, "ufw allow 32000/tcp") {
			t.Error("preexisting TCP rule changed")
		}
		if strings.Contains(cmd, "ufw allow 32000/udp") {
			udpAdded = true
			return "", 1
		}
		if strings.Contains(cmd, "ufw delete allow 32000/tcp") {
			t.Error("preexisting TCP rule deleted")
		}
		if strings.Contains(cmd, "ufw delete allow 32000/udp") {
			deletedUDP = true
		}
		return "", 0
	}
	s := deploymentSession(t, server)
	f := ubuntuFacts()
	f["singbox_path"] = "/usr/bin/sing-box"
	f["ufw"] = "Status: active"
	s.facts = f
	r := evaluate(f, privilegeRoot)
	s.report = &r
	if _, err := s.Deploy(context.Background(), 32000, nil); err == nil || !deletedUDP {
		t.Fatalf("err=%v partial UDP rollback=%v", err, deletedUDP)
	}
}

func TestFailedCommitNeverReportsSuccess(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	failed := false
	removed := false
	server.respond = func(cmd, input string) (string, int) {
		if strings.Contains(cmd, statePath+".xdial-tmp") && input != "" {
			var st state
			if err := json.Unmarshal([]byte(input), &st); err != nil {
				t.Error(err)
			}
			if !st.InProgress {
				failed = true
				return "", 1
			}
		}
		if strings.Contains(cmd, "rm -rf "+configDir) {
			removed = true
		}
		return "", 0
	}
	s := deploymentSession(t, server)
	s.facts = ubuntuFacts()
	r := evaluate(s.facts, privilegeRoot)
	s.report = &r
	if _, err := s.Deploy(context.Background(), 32000, nil); err == nil || !failed || !removed {
		t.Fatalf("err=%v commit failed=%v rolled back=%v", err, failed, removed)
	}
}

// The peer acknowledges cancellation without closing the transport, or ignores
// it entirely. Exercise the same Deploy compensation with both peer behaviours.
func TestCancellationRollbackWithResponsiveAndSilentPeer(t *testing.T) {
	for _, responsive := range []bool{true, false} {
		t.Run(map[bool]string{true: "responsive", false: "silent"}[responsive], func(t *testing.T) {
			server := newTestServer(t, "root", "secret")
			started := make(chan struct{})
			var restored atomic.Bool
			server.handleChannel = func(ch ssh.Channel, requests <-chan *ssh.Request) {
				defer ch.Close()
				waiting := false
				for request := range requests {
					switch request.Type {
					case "exec":
						var payload struct{ Command string }
						ssh.Unmarshal(request.Payload, &payload)
						request.Reply(true, nil)
						io.ReadAll(ch)
						if strings.Contains(payload.Command, " check -c ") {
							waiting = true
							close(started)
							continue
						}
						if strings.Contains(payload.Command, "cp -p "+configPath+".previous ") {
							restored.Store(true)
						}
						ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{0}))
						return
					case "signal":
						if waiting && responsive {
							ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{143}))
							return
						}
					}
				}
			}
			s := deploymentSession(t, server)
			f := ubuntuFacts()
			f["singbox_path"] = "/usr/bin/sing-box"
			config, _ := serverConfigJSON(31000, "AAAAAAAAAAAAAAAAAAAAAA==")
			f["xdial_config"] = encodeTestConfig(config)
			f["xdial_service"] = "active"
			s.facts = f
			r := evaluate(f, privilegeRoot)
			s.report = &r
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() { _, err := s.Deploy(ctx, 32000, nil); done <- err }()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("command never started")
			}
			cancel()
			select {
			case err := <-done:
				if responsive {
					if AsError(err).Code != "cancelled" || !restored.Load() {
						t.Fatalf("err=%v restored=%v", err, restored.Load())
					}
					// No delayed cancellation callback may close the transport during later undo.
					time.Sleep(cancellationGrace + 10*time.Millisecond)
					if _, err := s.run(context.Background(), "true", nil); err != nil {
						t.Fatalf("rollback connection lost: %v", err)
					}
				} else if AsError(err).Code != "undo_incomplete" {
					t.Fatalf("silent peer must retain recovery: %v", err)
				}
			case <-time.After(cancellationGrace + time.Second):
				t.Fatal("cancel was not bounded")
			}
		})
	}
}

func TestRetiredFirewallOwnershipIsNotReusedAcrossDeployments(t *testing.T) {
	for _, cleanupFails := range []bool{false, true} {
		t.Run(map[bool]string{false: "removed", true: "cleanup failed"}[cleanupFails], func(t *testing.T) {
			server := newTestServer(t, "root", "secret")
			old := []string{"31000/tcp", "31000/udp"}
			latest := state{Version: 1, CreatedAt: 10, OwnedUFW: old}
			rules := map[string]bool{old[0]: true, old[1]: true}
			retiredDeletes := 0
			server.respond = func(cmd, input string) (string, int) {
				if strings.Contains(cmd, statePath+".xdial-tmp") && input != "" {
					latest = state{}
					if err := json.Unmarshal([]byte(input), &latest); err != nil {
						t.Error(err)
					}
				}
				if strings.Contains(cmd, "ufw show added") {
					var out strings.Builder
					for rule := range rules {
						out.WriteString("ufw allow " + rule + "\n")
					}
					return out.String(), 0
				}
				for _, port := range []string{"31000", "32000", "33000"} {
					for _, proto := range []string{"tcp", "udp"} {
						rule := port + "/" + proto
						if strings.Contains(cmd, "ufw allow "+rule+" comment") {
							rules[rule] = true
						}
						if strings.Contains(cmd, "ufw delete allow "+rule) {
							if port == "31000" {
								retiredDeletes++
								if cleanupFails {
									return "", 1
								}
							}
							delete(rules, rule)
						}
					}
				}
				return "", 0
			}
			s := deploymentSession(t, server)
			setBaseline := func(port int) {
				f := ubuntuFacts()
				f["singbox_path"] = "/usr/bin/sing-box"
				f["ufw"] = "Status: active"
				config, _ := serverConfigJSON(port, "AAAAAAAAAAAAAAAAAAAAAA==")
				f["xdial_config"] = encodeTestConfig(config)
				f["xdial_service"] = "active"
				raw, _ := json.Marshal(latest)
				f["xdial_state"] = encodeTestConfig(raw)
				s.facts = f
				r := evaluate(f, privilegeRoot)
				s.report = &r
			}
			setBaseline(31000)
			if _, err := s.Deploy(context.Background(), 32000, nil); err != nil {
				t.Fatal(err)
			}
			if len(latest.OwnedUFW) != 2 || contains(latest.OwnedUFW, "31000/tcp") {
				t.Fatalf("retired ownership: %v", latest.OwnedUFW)
			}
			rules["31000/tcp"] = true
			rules["31000/udp"] = true // administrator takes over the retired port
			before := retiredDeletes
			setBaseline(32000)
			if _, err := s.Deploy(context.Background(), 32000, nil); err != nil {
				t.Fatal(err)
			}
			setBaseline(32000)
			if _, err := s.Deploy(context.Background(), 33000, nil); err != nil {
				t.Fatal(err)
			}
			if before != retiredDeletes || !rules["31000/tcp"] || !rules["31000/udp"] {
				t.Fatal("retired port deleted again")
			}
		})
	}
}

func TestCancelDuringExecStartupSignalsOnlyAfterAcknowledgement(t *testing.T) {
	server := newTestServer(t, "root", "secret")
	entered := make(chan struct{})
	release := make(chan struct{})
	var earlySignal atomic.Bool
	server.handleChannel = func(ch ssh.Channel, requests <-chan *ssh.Request) {
		defer ch.Close()
		for request := range requests {
			switch request.Type {
			case "exec":
				close(entered)
				<-release
				// Give a wrongly eager cancellation callback time to send its signal.
				select {
				case <-requests:
					earlySignal.Store(true)
				case <-time.After(50 * time.Millisecond):
				}
				request.Reply(true, nil)
			case "signal":
				ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{143}))
				return
			}
		}
	}
	s := deploymentSession(t, server)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := s.run(ctx, "sleep", nil); done <- err }()
	<-entered
	cancel()
	close(release)
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) || earlySignal.Load() {
			t.Fatalf("err=%v signal before exec=%v", err, earlySignal.Load())
		}
	case <-time.After(cancellationGrace + time.Second):
		t.Fatal("startup cancellation stuck")
	}
	s.mu.Lock()
	closed := s.closed
	s.mu.Unlock()
	if closed {
		t.Fatal("responsive startup destroyed rollback connection")
	}
}

func TestExistingServiceBootPolicyPreserved(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		for _, active := range []bool{true, false} {
			for _, outcome := range []string{"success", "start failure", "commit failure", "cancel", "recovery"} {
				t.Run(fmt.Sprintf("enabled=%v/active=%v/%s", enabled, active, outcome), func(t *testing.T) {
					server := newTestServer(t, "root", "secret")
					boot, running := enabled, active
					commitFailed := false
					server.respond = func(cmd, input string) (string, int) {
						if strings.Contains(cmd, "systemctl enable "+serviceName) {
							boot = true
						}
						if strings.Contains(cmd, "systemctl disable ") {
							boot = false
						}
						if strings.Contains(cmd, "systemctl restart "+serviceName) {
							running = true
						}
						if strings.Contains(cmd, "systemctl stop "+serviceName) {
							running = false
						}
						if outcome == "start failure" && strings.Contains(cmd, "NRestarts") {
							return "", 1
						}
						if outcome == "commit failure" && strings.Contains(cmd, statePath+".xdial-tmp") && input != "" {
							var st state
							json.Unmarshal([]byte(input), &st)
							if !st.InProgress && !commitFailed {
								commitFailed = true
								return "", 1
							}
						}
						return "", 0
					}
					s := deploymentSession(t, server)
					baseline := state{Version: 1, CreatedAt: 10}
					if outcome == "recovery" {
						running = true // interrupted start changed the running state
						if _, err := s.recoverInterrupted(context.Background(), state{Version: 1, InProgress: true, Baseline: &baseline, WasActive: active, Created: []string{"config_moved", "service"}}); err != nil {
							t.Fatal(err)
						}
					} else {
						f := ubuntuFacts()
						f["singbox_path"] = "/usr/bin/sing-box"
						config, _ := serverConfigJSON(31000, "AAAAAAAAAAAAAAAAAAAAAA==")
						f["xdial_config"] = encodeTestConfig(config)
						f["xdial_service"] = "inactive"
						if active {
							f["xdial_service"] = "active"
						}
						raw, _ := json.Marshal(baseline)
						f["xdial_state"] = encodeTestConfig(raw)
						s.facts = f
						r := evaluate(f, privilegeRoot)
						s.report = &r
						ctx, cancel := context.WithCancel(context.Background())
						defer cancel()
						_, err := s.Deploy(ctx, 32000, func(e Event) {
							if outcome == "cancel" && e.Step == "start" && e.Status == "done" {
								cancel()
							}
						})
						if (err == nil) != (outcome == "success") {
							t.Fatalf("outcome=%s err=%v", outcome, err)
						}
					}
					wantRunning := active || outcome == "success"
					if boot != enabled || running != wantRunning {
						t.Fatalf("boot=%v want=%v running=%v want=%v", boot, enabled, running, wantRunning)
					}
				})
			}
		}
	}
}
