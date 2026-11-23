//go:build linux && !android

package linuxservice

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/controlpipe"
	"github.com/kafeifei/xdial/core/linuxcapture"
	mDNS "github.com/miekg/dns"
	"golang.org/x/sys/unix"
)

func TestResolverAdmission(t *testing.T) {
	for _, s := range []string{"nameserver 127.0.0.53\n", "nameserver 192.0.2.53\nsearch example.com\n", "nameserver 192.0.2.53\nnameserver 192.0.2.54\n", "options rotate\n", "nameserver ::1\n"} {
		if _, e := resolverAddress([]byte(s)); e == nil {
			t.Fatalf("accepted unsupported OS semantics %q", s)
		}
	}
	if v, e := resolverAddress([]byte("# fixture\nnameserver 192.0.2.53 # OS\n")); e != nil || v != "192.0.2.53" {
		t.Fatal(v, e)
	}
}

// Every network/admin action below is guarded by the disposable guest marker.
func isolated(t *testing.T) {
	t.Helper()
	b, _ := os.ReadFile("/proc/cmdline")
	dmi, _ := os.ReadFile("/sys/class/dmi/id/product_name")
	fullGuest := os.Getenv("XDIAL_DISTRO_VM") == "1" && strings.TrimSpace(string(dmi)) == "XDial-isolated-distro"
	if os.Getenv("XDIAL_ISOLATED_VM") != "1" || (!bytes.Contains(b, []byte("xdial_isolated_vm=transparent")) && !fullGuest) {
		t.Skip("isolated kernel guest only")
	}
}
func cmdOK(t *testing.T, name string, args ...string) {
	t.Helper()
	out, e := exec.Command(name, args...).CombinedOutput()
	if e != nil {
		t.Fatalf("%s: %v %s", name, e, out)
	}
}
func markedListenConfig(mark uint32) net.ListenConfig {
	return net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var e error
		outer := c.Control(func(fd uintptr) {
			e = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, int(mark))
			if e == nil {
				e = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_REUSEADDR, 1)
			}
		})
		if outer != nil {
			return outer
		}
		return e
	}}
}
func serviceProfile(proxyPort int, bind bool) []byte {
	p := config.Profile{Lines: []config.Line{{ID: "direct", Name: "Direct", Type: config.LineTypeDirect, Enabled: true}, {ID: "fixture", Name: "Fixture", Type: config.LineTypeShadowsocks, Enabled: true, SSServer: "127.0.0.2", SSPort: proxyPort, SSMethod: "none", SSPass: "non-secret"}}, RuleSets: []config.RuleSet{{ID: "app", Name: "App", Type: config.RuleSetTypeApplication, Enabled: true, Processes: []string{"/service-proxy"}}}, Scenarios: []config.Scenario{{ID: "one", Name: "One", DefaultLineID: "direct"}}, ActiveScenarioID: "one"}
	if bind {
		p.Scenarios[0].Bindings = []config.RuleBinding{{RuleSetID: "app", LineID: "fixture"}}
	}
	b, _ := json.Marshal(p)
	return b
}
func childCommand(t *testing.T, uid uint32, mode, socket string, payload []byte) ([]byte, error) {
	t.Helper()
	cmd := exec.Command("/service-tests", "-test.run=^TestServiceChild$", "-test.v")
	cmd.Env = append(os.Environ(), "XDIAL_SERVICE_CHILD="+mode, "XDIAL_SERVICE_SOCKET="+socket)
	cmd.Stdin = bytes.NewReader(payload)
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: uid, NoSetGroups: true}}
	return cmd.CombinedOutput()
}

var testInstance string

func callAsUser(t *testing.T, socket, op string, revision uint64, profile []byte) controlpipe.Response {
	t.Helper()
	var payload []byte
	if op != "status" {
		payload, _ = json.Marshal(Mutation{ExpectedInstance: testInstance, ExpectedRevision: revision, Profile: profile})
	}
	q, _ := json.Marshal(controlpipe.Request{Operation: op, Payload: payload})
	out, e := childCommand(t, 1001, "request", socket, q)
	if e != nil {
		t.Fatalf("client %s: %v %s", op, e, out)
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "RESPONSE ") {
			var r controlpipe.Response
			if e = json.Unmarshal([]byte(strings.TrimPrefix(line, "RESPONSE ")), &r); e != nil {
				t.Fatal(e)
			}
			if op == "status" {
				var st Status
				json.Unmarshal(r.Payload, &st)
				testInstance = st.Instance
			}
			return r
		}
	}
	t.Fatalf("missing response %s", out)
	return controlpipe.Response{}
}
func TestServiceChild(t *testing.T) {
	mode := os.Getenv("XDIAL_SERVICE_CHILD")
	if mode == "" {
		t.Skip("child only")
	}
	isolated(t)
	if mode == "inherited-deny" {
		f := os.NewFile(3, "inherited-control")
		conn, e := net.FileConn(f)
		f.Close()
		if e != nil {
			t.Fatal(e)
		}
		defer conn.Close()
		c := conn.(*net.UnixConn)
		b, _ := json.Marshal(controlpipe.Request{Version: 1, ID: 1, Operation: "status"})
		packet := make([]byte, 4+len(b))
		binary.BigEndian.PutUint32(packet, uint32(len(b)))
		copy(packet[4:], b)
		c.SetDeadline(time.Now().Add(time.Second))
		if _, _, e = c.WriteMsgUnix(packet, nil, nil); e != nil {
			t.Fatal(e)
		}
		buf := make([]byte, 1000)
		if n, e := c.Read(buf); n != 0 || e == nil {
			t.Fatal("inherited unauthorized credential accepted")
		}
		return
	}
	if mode == "request" || mode == "deny" {
		var q controlpipe.Request
		if e := json.NewDecoder(os.Stdin).Decode(&q); e != nil {
			t.Fatal(e)
		}
		r, e := controlpipe.CallUnix(context.Background(), os.Getenv("XDIAL_SERVICE_SOCKET"), 0, q)
		if mode == "deny" {
			if e == nil {
				t.Fatal("unauthorized UID admitted")
			}
			return
		}
		if e != nil {
			t.Fatal(e)
		}
		b, _ := json.Marshal(r)
		fmt.Println("RESPONSE " + string(b))
		return
	}
	if mode == "echo" || mode == "closed" {
		b, _ := io.ReadAll(os.Stdin)
		c, e := net.DialTimeout("tcp4", string(b), 2*time.Second)
		if e != nil {
			t.Fatal(e)
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(2 * time.Second))
		c.Write([]byte("hello"))
		reply := make([]byte, 5)
		_, e = io.ReadFull(c, reply)
		if mode == "closed" {
			if e == nil {
				t.Fatal("proxy fixture unexpectedly echoed")
			}
			if timeout, ok := e.(net.Error); ok && timeout.Timeout() {
				t.Fatal("timeout is not proxy close evidence")
			}
			return
		}
		if e != nil || string(reply) != "hello" {
			t.Fatal(e, string(reply))
		}
		return
	}
	t.Fatal("unknown child mode")
}
func TestLinuxServiceKernelLifecycle(t *testing.T) {
	isolated(t)
	if os.Geteuid() != 0 {
		t.Fatal("guest root required")
	}
	root := "/run/xdial-service-test"
	if e := os.Mkdir(root, 0700); e != nil {
		t.Fatal(e)
	}
	defer os.RemoveAll(root)
	runtime := "/run/xdial-service-ipc"
	os.Mkdir(runtime, 0755)
	defer os.RemoveAll(runtime)
	socket := filepath.Join(runtime, "control.sock")
	plan := linuxcapture.Plan{CaptureMark: 1 << 16, BypassMark: 1 << 17, Table: 50000, Priority: 32000, Listener: "127.0.0.1:31234"}
	policy, _ := json.Marshal(Policy{1, 1001, socket, plan})
	os.WriteFile(filepath.Join(root, "policy.json"), policy, 0600)
	cmdOK(t, "ip", "route", "add", "192.0.2.54/32", "dev", "lo")
	defer exec.Command("ip", "route", "del", "192.0.2.54/32", "dev", "lo").Run()
	cmdOK(t, "ip", "addr", "add", "192.0.2.53/32", "dev", "lo")
	defer exec.Command("ip", "addr", "del", "192.0.2.53/32", "dev", "lo").Run()
	oldResolv, _ := os.ReadFile("/etc/resolv.conf")
	os.WriteFile("/etc/resolv.conf", []byte("nameserver 192.0.2.53\n"), 0644)
	defer os.WriteFile("/etc/resolv.conf", oldResolv, 0644)
	lc := markedListenConfig(plan.BypassMark)
	dns, e := lc.ListenPacket(context.Background(), "udp4", "192.0.2.53:53")
	if e != nil {
		t.Fatal(e)
	}
	defer dns.Close()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, a, e := dns.ReadFrom(buf)
			if e != nil {
				return
			}
			var q mDNS.Msg
			if q.Unpack(buf[:n]) != nil {
				continue
			}
			r := new(mDNS.Msg)
			r.SetReply(&q)
			if len(q.Question) > 0 {
				r.Answer = []mDNS.RR{&mDNS.A{Hdr: mDNS.RR_Header{Name: q.Question[0].Name, Rrtype: mDNS.TypeA, Class: mDNS.ClassINET, Ttl: 1}, A: net.IPv4(192, 0, 2, 10)}}
			}
			b, _ := r.Pack()
			dns.WriteTo(b, a)
		}
	}()
	defer func() { dns.Close(); wg.Wait() }()
	echo, e := lc.Listen(context.Background(), "tcp4", "127.0.0.2:0")
	if e != nil {
		t.Fatal(e)
	}
	defer echo.Close()
	go func() {
		for {
			c, e := echo.Accept()
			if e != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	proxy, e := lc.Listen(context.Background(), "tcp4", "127.0.0.2:0")
	if e != nil {
		t.Fatal(e)
	}
	defer proxy.Close()
	targets := make(chan string, 8)
	go func() {
		for {
			c, e := proxy.Accept()
			if e != nil {
				return
			}
			go func() {
				defer c.Close()
				c.SetDeadline(time.Now().Add(2 * time.Second))
				b := make([]byte, 7)
				if _, e := io.ReadFull(c, b); e == nil && b[0] == 1 {
					targets <- net.JoinHostPort(net.IP(b[1:5]).String(), strconv.Itoa(int(b[5])<<8|int(b[6])))
				}
			}()
		}
	}()
	var process *exec.Cmd
	var wait chan error
	var output bytes.Buffer
	start := func() {
		output.Reset()
		process = exec.Command("/app-service", "serve", "--state", root)
		process.Stdout = &output
		process.Stderr = &output
		if e := process.Start(); e != nil {
			t.Fatal(e)
		}
		wait = make(chan error, 1)
		go func(c *exec.Cmd) { wait <- c.Wait() }(process)
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if c, e := net.DialTimeout("unixpacket", socket, 20*time.Millisecond); e == nil {
				c.Close()
				return
			}
			select {
			case e := <-wait:
				t.Fatalf("service startup: %v %s", e, output.String())
			default:
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatal("service startup timeout")
	}
	stop := func(kill bool) {
		if kill {
			process.Process.Kill()
		} else {
			process.Process.Signal(syscall.SIGTERM)
		}
		select {
		case e := <-wait:
			if !kill && e != nil {
				t.Fatalf("service stop: %v %s", e, output.String())
			}
		case <-time.After(5 * time.Second):
			process.Process.Kill()
			t.Fatal("service did not exit")
		}
		process = nil
	}
	defer func() {
		if process != nil {
			stop(true)
		}
	}()
	start()
	deny, _ := json.Marshal(controlpipe.Request{Operation: "status"})
	if out, e := childCommand(t, 1002, "deny", socket, deny); e != nil {
		t.Fatal(e, string(out))
	}
	duplicate := exec.Command("/app-service", "serve", "--state", root)
	if e := duplicate.Run(); e == nil {
		t.Fatal("duplicate service admitted")
	}
	require := func(r controlpipe.Response, code string) {
		t.Helper()
		if r.Code != code {
			t.Fatalf("wanted %s: %+v service=%s", code, r, output.String())
		}
	}
	require(callAsUser(t, socket, "status", 0, nil), "ok")
	require(callAsUser(t, socket, "connect", 99, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "revision_conflict")
	require(callAsUser(t, socket, "connect", 0, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "ok")
	client := &mDNS.Client{Net: "udp", Timeout: 2 * time.Second}
	q := new(mDNS.Msg)
	q.SetQuestion("service.test.", mDNS.TypeA)
	answer, _, e := client.Exchange(q, "192.0.2.54:53")
	if e != nil || len(answer.Answer) != 1 || answer.Answer[0].(*mDNS.A).A.String() != "192.0.2.10" {
		t.Fatalf("captured DNS: %v %+v", e, answer)
	}
	old, e := net.Dial("tcp4", echo.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer old.Close()
	roundtrip := func(c net.Conn) {
		t.Helper()
		c.SetDeadline(time.Now().Add(2 * time.Second))
		c.Write([]byte("ping"))
		b := make([]byte, 4)
		if _, e := io.ReadFull(c, b); e != nil || string(b) != "ping" {
			t.Fatal(e, string(b))
		}
	}
	roundtrip(old)
	require(callAsUser(t, socket, "switch", 1, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, true)), "ok")
	roundtrip(old)
	app := func(path, mode string) {
		t.Helper()
		cmd := exec.Command(path, "-test.run=^TestServiceChild$", "-test.v")
		cmd.Env = append(os.Environ(), "XDIAL_SERVICE_CHILD="+mode)
		cmd.Stdin = strings.NewReader(echo.Addr().String())
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 1001, Gid: 1001, NoSetGroups: true}}
		out, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatal(e, string(out))
		}
	}
	app("/service-allow", "echo")
	app("/service-proxy", "closed")
	select {
	case v := <-targets:
		if v != echo.Addr().String() {
			t.Fatal("wrong proxy original target", v)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("application did not reach selected proxy")
	}
	// Rapid commits must not let the earlier timer retire the later generation.
	newer, e := net.Dial("tcp4", echo.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer newer.Close()
	roundtrip(newer)
	require(callAsUser(t, socket, "switch", 2, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "ok")
	roundtrip(newer)
	time.Sleep(1100 * time.Millisecond)
	newer.SetReadDeadline(time.Now().Add(time.Second))
	var retiredByte [1]byte
	if _, e = newer.Read(retiredByte[:]); e == nil {
		t.Fatal("second generation not retired")
	}
	old.SetReadDeadline(time.Now().Add(time.Second))
	var b [1]byte
	if _, e = old.Read(b[:]); e == nil {
		t.Fatal("old generation not retired")
	}
	oldInstance := testInstance
	stop(true)
	start()
	require(callAsUser(t, socket, "status", 0, nil), "ok")
	newInstance := testInstance
	if newInstance == oldInstance {
		t.Fatal("service instance reused")
	}
	testInstance = oldInstance
	require(callAsUser(t, socket, "connect", 0, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "revision_conflict")
	testInstance = newInstance
	require(callAsUser(t, socket, "connect", 0, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "ok")
	// A resolver stub appearing during a live connection must withdraw capture,
	// not recurse into it or substitute a public resolver.
	os.WriteFile("/etc/resolv.conf", []byte("nameserver 127.0.0.53\n"), 0644)
	deadline := time.Now().Add(3 * time.Second)
	stopped := false
	for time.Now().Before(deadline) {
		r := callAsUser(t, socket, "status", 0, nil)
		var st Status
		json.Unmarshal(r.Payload, &st)
		if st.Revision == 2 {
			var state struct{ Desired bool }
			json.Unmarshal(st.Connection, &state)
			if state.Desired {
				t.Fatal("network invalidation retained intent")
			}
			stopped = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !stopped {
		t.Fatal("resolver change not observed")
	}
	require(callAsUser(t, socket, "connect", 2, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "unsupported_underlay")
	os.WriteFile("/etc/resolv.conf", []byte("nameserver 192.0.2.53\n"), 0644)
	require(callAsUser(t, socket, "connect", 2, serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)), "ok")
	require(callAsUser(t, socket, "disconnect", 3, nil), "ok")
	setResolver := func(contents string) {
		t.Helper()
		if e := os.WriteFile("/etc/resolv.conf", []byte(contents), 0644); e != nil {
			t.Fatal(e)
		}
	}
	waitPhase := func(want string) uint64 {
		t.Helper()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			var st Status
			var connection struct{ Phase string }
			reply := callAsUser(t, socket, "status", 0, nil)
			if json.Unmarshal(reply.Payload, &st) == nil && json.Unmarshal(st.Connection, &connection) == nil && connection.Phase == want {
				return st.Revision
			}
			time.Sleep(25 * time.Millisecond)
		}
		t.Fatalf("never reached %s", want)
		return 0
	}
	setResolver("")
	profile := serviceProfile(proxy.Addr().(*net.TCPAddr).Port, false)
	require(callAsUser(t, socket, "connect", waitPhase("disconnected"), profile), "waiting_network")
	setResolver("nameserver 192.0.2.53\n")
	waitPhase("connected")
	app("/service-allow", "echo")
	setResolver("")
	require(callAsUser(t, socket, "disconnect", waitPhase("waiting_network"), nil), "ok")
	setResolver("nameserver 192.0.2.53\n")
	waitPhase("disconnected")
	stop(false)
	if _, e = os.Stat(filepath.Join(root, "capture/session.json")); !os.IsNotExist(e) {
		t.Fatal("journal remains", e)
	}
	if e = linuxcapture.Recover(filepath.Join(root, "capture")); e != nil {
		t.Fatal(e)
	}
	fmt.Println("XDIAL_SERVICE_KERNEL_OK")
}

func TestUnixControlKernelMessageCredentials(t *testing.T) {
	isolated(t)
	dir := "/run/xdial-message-test"
	os.Mkdir(dir, 0755)
	defer os.RemoveAll(dir)
	socket := dir + "/control"
	var called atomic.Int32
	server, e := controlpipe.ListenUnix(socket, 0, func(ctx context.Context, id controlpipe.UnixIdentity, q controlpipe.Request) controlpipe.Response {
		called.Add(1)
		if id.UID != 0 || id.PID <= 0 {
			t.Error("missing kernel identity")
		}
		return controlpipe.Response{Code: "ok"}
	})
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	c, e := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: socket, Net: "unixpacket"})
	if e != nil {
		t.Fatal(e)
	}
	f, e := c.File()
	if e != nil {
		t.Fatal(e)
	}
	cmd := exec.Command("/service-tests", "-test.run=^TestServiceChild$", "-test.v")
	cmd.ExtraFiles = []*os.File{f}
	cmd.Env = append(os.Environ(), "XDIAL_SERVICE_CHILD=inherited-deny")
	cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 1002, Gid: 1002, NoSetGroups: true}}
	out, e := cmd.CombinedOutput()
	f.Close()
	c.Close()
	if e != nil {
		t.Fatal(e, string(out))
	}
	if called.Load() != 0 {
		t.Fatal("authenticated only accept-time UID")
	}
	for _, invalid := range []string{`{"version":1,"id":1,"operation":"status","uid":0}`, `{"version":1,"id":1,"operation":"status","pid":1}`} {
		c, e := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: socket, Net: "unixpacket"})
		if e != nil {
			t.Fatal(e)
		}
		c.SetDeadline(time.Now().Add(time.Second))
		p := make([]byte, 4+len(invalid))
		binary.BigEndian.PutUint32(p, uint32(len(invalid)))
		copy(p[4:], invalid)
		c.WriteMsgUnix(p, nil, nil)
		var b [100]byte
		n, _ := c.Read(b[:])
		c.Close()
		if n != 0 {
			t.Fatal("self-asserted identity accepted")
		}
	}
	r, e := controlpipe.CallUnix(context.Background(), socket, 0, controlpipe.Request{Operation: "status"})
	if e != nil || r.Code != "ok" || called.Load() != 1 {
		t.Fatal("legitimate call", e, r, called.Load())
	}
	if _, e = controlpipe.CallUnix(context.Background(), socket, 1002, controlpipe.Request{Operation: "status"}); e == nil {
		t.Fatal("wrong server UID accepted")
	}
	if called.Load() != 1 {
		t.Fatal("payload sent to wrong server")
	}
}
