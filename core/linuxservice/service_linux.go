//go:build linux && !android

// Package linuxservice joins the shared configuration/control plane to the
// privileged capture transaction. Clients submit Profiles, never kernel rules.
package linuxservice

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/controlpipe"
	"github.com/kafeifei/xdial/core/libbox"
	"github.com/kafeifei/xdial/core/linuxcapture"
	"github.com/kafeifei/xdial/core/linuxmaintenance"
	"github.com/kafeifei/xdial/core/linuxresolver"
	"github.com/kafeifei/xdial/core/recovery"
	"golang.org/x/sys/unix"
)

type Policy struct {
	Version    int               `json:"version"`
	AllowedUID uint32            `json:"allowedUID"`
	Socket     string            `json:"socket"`
	Capture    linuxcapture.Plan `json:"capture"`
}
type Mutation struct {
	ExpectedInstance string          `json:"expectedInstance"`
	ExpectedRevision uint64          `json:"expectedRevision"`
	Profile          json.RawMessage `json:"profile,omitempty"`
}
type Status struct {
	Instance              string          `json:"instance"`
	NetworkObserverFailed bool            `json:"networkObserverFailed"`
	Revision              uint64          `json:"revision"`
	Connection            json.RawMessage `json:"connection"`
	CleanupRequired       bool            `json:"cleanupRequired"`
}
type Service struct {
	policy          Policy
	instance        string
	root            string
	lock            io.Closer
	socketLock      *os.File
	server          *controlpipe.UnixServer
	gate            chan struct{}
	ctx             context.Context
	cancel          context.CancelFunc
	core            *libbox.Libbox
	resolver        *linuxresolver.Lease
	capture         *linuxcapture.Session
	controller      *recovery.ConnectionController
	revision        uint64
	cleanupRequired bool
	retired         *time.Timer
	watcher         *fsnotify.Watcher
	observer        sync.WaitGroup
	profile         json.RawMessage // held only while the user wants this connection
	retry           *time.Timer
	underlay        string
	networkFailed   bool
	closeOnce       sync.Once
	closeErr        error
}

func strictJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return e
	}
	if d.Decode(new(any)) != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

// Open requires an installer-created private state directory with policy.json.
// It reconciles the journal before exposing IPC and never reconnects on restart.
func Open(root string) (s *Service, err error) {
	lock, err := linuxcapture.LockServiceDirectory(root)
	if err != nil {
		return nil, err
	}
	s = &Service{root: root, lock: lock, gate: make(chan struct{}, 1), controller: recovery.NewConnectionController()}
	s.gate <- struct{}{}
	s.ctx, s.cancel = context.WithCancel(context.Background())
	nonce := make([]byte, 16)
	if _, err = rand.Read(nonce); err != nil {
		lock.Close()
		return nil, err
	}
	s.instance = hex.EncodeToString(nonce)
	opened := s
	defer func() {
		if err != nil {
			opened.Close()
		}
	}()
	raw, err := privateFile(filepath.Join(root, "policy.json"), 16384)
	if err != nil {
		return nil, err
	}
	if err = strictJSON(raw, &s.policy); err != nil {
		return nil, err
	}
	if s.policy.Version != 1 || s.policy.AllowedUID == 0 {
		return nil, errors.New("installer must select one unprivileged UID")
	}
	if err = s.policy.Capture.Validate(); err != nil {
		return nil, err
	}
	for _, name := range []string{"capture", "cache"} {
		path := filepath.Join(root, name)
		if err = os.Mkdir(path, 0700); err != nil && !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		check, e := linuxcapture.LockServiceDirectory(path)
		if e != nil {
			return nil, e
		}
		check.Close()
	}
	if err = linuxcapture.Recover(filepath.Join(root, "capture")); err != nil {
		return nil, err
	}
	if s.socketLock, err = lockSocket(s.policy.Socket); err != nil {
		return nil, err
	}
	if err = s.observeNetwork(); err != nil {
		return nil, err
	}
	s.server, err = controlpipe.ListenUnix(s.policy.Socket, s.policy.AllowedUID, s.handle)
	if err != nil {
		return nil, err
	}
	return s, nil
}
func privateFile(path string, limit int) ([]byte, error) {
	fd, e := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	var st unix.Stat_t
	if e = unix.Fstat(fd, &st); e != nil {
		return nil, e
	}
	if st.Uid != 0 || st.Mode&0077 != 0 || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Nlink != 1 {
		return nil, errors.New("policy must be a private root-owned regular file")
	}
	b, e := io.ReadAll(io.LimitReader(f, int64(limit+1)))
	if len(b) > limit {
		return nil, errors.New("policy exceeds limit")
	}
	return b, e
}
func lockSocket(path string) (*os.File, error) {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path || len(path) > 100 {
		return nil, errors.New("invalid installed socket path")
	}
	// Every ancestor must be root owned, non-writable, and non-symlink. Holding
	// this endpoint's separate lock also excludes a different state directory.
	for p := filepath.Dir(path); ; p = filepath.Dir(p) {
		var st unix.Stat_t
		if e := unix.Lstat(p, &st); e != nil {
			return nil, e
		}
		if st.Uid != 0 || st.Mode&0022 != 0 || st.Mode&unix.S_IFMT != unix.S_IFDIR {
			return nil, errors.New("unsafe control directory")
		}
		if p == "/" {
			break
		}
	}
	fd, e := unix.Open(path+".lock", unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_CLOEXEC|unix.O_NONBLOCK, 0600)
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), path+".lock")
	var st unix.Stat_t
	if e = unix.Fstat(fd, &st); e == nil && (st.Uid != 0 || st.Mode&0077 != 0 || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Nlink != 1) {
		e = errors.New("unsafe endpoint lock")
	}
	if e == nil {
		e = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB)
	}
	if e != nil {
		f.Close()
		return nil, e
	}
	if e = unix.Lstat(path, &st); e == nil {
		if st.Uid != 0 || st.Mode&unix.S_IFMT != unix.S_IFSOCK {
			f.Close()
			return nil, errors.New("control path occupied")
		}
		e = os.Remove(path)
	}
	if e != nil && !errors.Is(e, os.ErrNotExist) {
		f.Close()
		return nil, e
	}
	return f, nil
}
func (s *Service) status() json.RawMessage {
	b, _ := json.Marshal(Status{Instance: s.instance, NetworkObserverFailed: s.networkFailed, Revision: s.revision, Connection: json.RawMessage(s.controller.Snapshot()), CleanupRequired: s.cleanupRequired})
	return b
}
func (s *Service) handle(ctx context.Context, _ controlpipe.UnixIdentity, req controlpipe.Request) controlpipe.Response {
	select {
	case <-ctx.Done():
		return controlpipe.Response{Code: "cancelled"}
	case <-s.ctx.Done():
		return controlpipe.Response{Code: "stopped"}
	case <-s.gate:
	}
	defer func() { s.gate <- struct{}{} }()
	response := func(code string) controlpipe.Response { return controlpipe.Response{Code: code, Payload: s.status()} }
	if req.Operation == "status" {
		if len(req.Payload) != 0 {
			return response("invalid_request")
		}
		return response("ok")
	}
	if req.Operation != "connect" && req.Operation != "switch" && req.Operation != "disconnect" {
		return response("unknown_operation")
	}
	var m Mutation
	if strictJSON(req.Payload, &m) != nil {
		return response("invalid_request")
	}
	if m.ExpectedInstance != s.instance || m.ExpectedRevision != s.revision {
		return response("revision_conflict")
	}
	if req.Operation == "disconnect" {
		if len(m.Profile) != 0 {
			return response("invalid_request")
		}
		s.revision++
		if s.disconnect() != nil {
			return response("cleanup_required")
		}
		return response("ok")
	}
	if req.Operation == "connect" && s.core == nil {
		parsed, err := config.ParseRuntimeProfile(m.Profile)
		if err != nil {
			return response("invalid_profile_or_missing_cache")
		}
		if _, err = config.BuildConnectionPlan(parsed); err != nil {
			return response("invalid_profile_or_missing_cache")
		}
		// An explicit retry supersedes a parked intent.
		s.cancelRecovery()
	}
	code := s.apply(ctx, req.Operation, m.Profile)
	if req.Operation == "connect" && s.core == nil && code != "waiting_network" {
		s.cancelRecovery()
	}
	return response(code)
}

var serviceClock = time.Now()
var errNoUnderlay = errors.New("no available underlay")
var errUnderlayChanged = errors.New("underlay changed")

// Caller holds gate; a resumed attempt passes the same admission, maintenance
// and capture checks as a user request.
func (s *Service) apply(ctx context.Context, operation string, profile json.RawMessage) string {
	lease, err := linuxmaintenance.ConnectionLease(s.root)
	if err != nil {
		return "maintenance_required"
	}
	defer lease.Close()
	if s.networkFailed {
		return "network_observer_failed"
	}
	if s.cleanupRequired {
		return "cleanup_required"
	}
	if (operation == "connect") != (s.core == nil) {
		return "invalid_state"
	}
	if err := s.watchResolver(); err != nil {
		return "unsupported_underlay"
	}
	if err := resolverIngressReady(); err != nil {
		return "unsupported_native_resolver_ingress"
	}
	if s.core == nil && usesResolvedStub() {
		l, e := linuxresolver.Open(s.ctx)
		if e != nil {
			return "unsupported_resolver_dependency"
		}
		s.resolver = l
	}
	defer func() {
		if s.core == nil && s.resolver != nil {
			s.resolver.Close()
			s.resolver = nil
		}
	}()
	dns, interfaces, identity, err := s.networkFacts()
	if err != nil {
		if operation == "connect" && errors.Is(err, errNoUnderlay) {
			s.controller.RequestConnection(true)
			s.controller.ObserveUnderlay("")
			if s.profile == nil {
				s.revision++
			}
			s.profile = profile
			return "waiting_network"
		}
		return "unsupported_underlay"
	}
	var config string
	if s.resolver != nil {
		config, err = libbox.GenerateLinuxResolvedConfig(string(profile), filepath.Join(s.root, "cache"), s.policy.Capture.BypassMark)
	} else {
		config, err = libbox.GenerateLinuxConfig(string(profile), dns, filepath.Join(s.root, "cache"), s.policy.Capture.BypassMark)
	}
	if err != nil {
		return "invalid_profile_or_missing_cache"
	}
	if err = ctx.Err(); err != nil {
		return "cancelled"
	}
	if s.core == nil {
		s.controller.RequestConnection(true)
		s.controller.ObserveUnderlay(identity)
		epoch := s.controller.NextAttempt(time.Since(serviceClock).Milliseconds())
		if epoch == 0 {
			return "waiting_network"
		}
		s.profile = profile
		s.revision++
		l := libbox.New(nil)
		s.core = l
		failureCode := "core_setup_failed"
		if err = l.ConfigureLinuxTProxy(s.policy.Capture.BypassMark); err == nil {
			err = l.SetNetworkInterfaces(interfaces)
		}
		if err == nil {
			failureCode = "core_start_failed"
			err = s.prepare(ctx, l, func() error { return l.StartStandalone(config) })
		}
		if err == nil {
			failureCode = "listener_start_failed"
			err = l.StartLinuxTProxy(s.policy.Capture.Listener, s.policy.Capture.BypassMark)
		}
		if err == nil {
			_, _, check, e := s.networkFacts()
			err = e
			if e == nil && check != identity {
				err = errUnderlayChanged
			}
		}
		if err == nil {
			err = ctx.Err()
		}
		if err == nil {
			err = s.ctx.Err()
		}
		if err == nil {
			failureCode = "capture_install_failed"
			if s.resolver == nil {
				s.capture, err = linuxcapture.Install(ctx, filepath.Join(s.root, "capture"), s.policy.Capture)
			} else {
				id, level, e := s.resolver.Scope()
				err = e
				if err == nil {
					s.capture, err = linuxcapture.InstallWithResolver(ctx, filepath.Join(s.root, "capture"), s.policy.Capture, linuxcapture.ResolverScope{ID: id, Level: level})
				}
				if err == nil {
					err = s.resolver.Validate(ctx)
				}
			}
		}
		if err != nil {
			if s.capture != nil {
				if e := s.capture.Close(); e != nil {
					s.cleanupRequired = true
				}
				s.capture = nil
			}
			s.stopCore()
			if e := linuxcapture.Recover(filepath.Join(s.root, "capture")); e != nil {
				s.cleanupRequired = true
			}
			networkFailure := errors.Is(err, errUnderlayChanged) || errors.Is(err, errNoUnderlay) ||
				(failureCode == "core_start_failed" && recovery.IsTransient(err))
			retryable := networkFailure && !s.cleanupRequired && ctx.Err() == nil
			now := time.Since(serviceClock).Milliseconds()
			s.controller.CompleteAttempt(epoch, false, retryable, now)
			if retryable {
				if delay := s.controller.RetryAfter(now); delay >= 0 {
					s.scheduleRetry(time.Duration(delay) * time.Millisecond)
				}
				return "waiting_network"
			}
			return failureCode
		}
		s.underlay = identity
		s.controller.CompleteAttempt(epoch, true, false, 0)
		s.observeResolverLease()
		return "ok"
	}
	// No two packet readers: libbox's stable listener admits a candidate without
	// inbounds. Keep old flows for one second after the single DNS/route commit.
	if s.retired != nil {
		s.retired.Stop()
		s.retired = nil
	}
	if err = s.core.RetireCommittedSwitch(); err != nil {
		return "switch_failed"
	}
	if err = s.prepare(ctx, s.core, func() error { return s.core.PrepareSwitch(config, "", interfaces, "", -1) }); err == nil {
		_, _, check, e := s.networkFacts()
		err = e
		if e == nil && check != identity {
			err = errors.New("underlay changed")
		}
	}
	if err == nil {
		err = ctx.Err()
	}
	if err == nil {
		err = s.ctx.Err()
	}
	if err == nil {
		err = s.core.CommitPreparedSwitch()
	}
	if err != nil {
		s.core.AbortPreparedSwitch()
		return "switch_failed"
	}
	s.profile = profile
	s.revision++
	committedCore, committedRevision := s.core, s.revision
	s.retired = time.AfterFunc(time.Second, func() {
		select {
		case <-s.ctx.Done():
			return
		case <-s.gate:
		}
		defer func() { s.gate <- struct{}{} }()
		if s.core == committedCore && s.revision == committedRevision {
			s.core.RetireCommittedSwitch()
		}
	})
	return "ok"
}
func (s *Service) stopCore() {
	if s.core != nil {
		s.core.Stop()
		s.core = nil
	}
	if s.resolver != nil {
		s.resolver.Close()
		s.resolver = nil
	}
}
func (s *Service) cancelRecovery() {
	s.controller.RequestConnection(false)
	s.profile = nil
	if s.retry != nil {
		s.retry.Stop()
		s.retry = nil
	}
}

func (s *Service) resume() {
	if s.core != nil || s.profile == nil || s.ctx.Err() != nil {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, 45*time.Second)
	defer cancel()
	switch s.apply(ctx, "connect", s.profile) {
	case "ok", "waiting_network":
	default:
		s.cancelRecovery()
	}
}

func (s *Service) scheduleRetry(delay time.Duration) {
	if s.retry != nil {
		s.retry.Stop()
	}
	revision := s.revision
	s.retry = time.AfterFunc(delay, func() {
		select {
		case <-s.ctx.Done():
			return
		case <-s.gate:
		}
		defer func() { s.gate <- struct{}{} }()
		if s.revision == revision {
			s.resume()
		}
	})
}

func (s *Service) disconnect() error {
	s.cancelRecovery()
	return s.withdraw()
}
func (s *Service) withdraw() error {
	if s.retired != nil {
		s.retired.Stop()
		s.retired = nil
	}
	if s.capture != nil {
		e := s.capture.Close()
		s.capture = nil
		if e != nil {
			s.cleanupRequired = true
			s.stopCore()
			return e
		}
	}
	s.stopCore()
	return nil
}
func (s *Service) Close() error {
	s.closeOnce.Do(func() {
		s.cancel()
		if s.watcher != nil {
			s.watcher.Close()
		}
		s.observer.Wait()
		if s.server != nil {
			s.server.Close()
		}
		<-s.gate
		s.closeErr = s.disconnect()
		s.gate <- struct{}{}
		if s.socketLock != nil {
			s.socketLock.Close()
		}
		if s.lock != nil {
			s.lock.Close()
		}
	})
	return s.closeErr
}

// This backend preserves a single OS resolver exactly. Search/split DNS and
// loopback stubs require a native protected backend and are not flattened.
func resolverAddress(b []byte) (string, error) {
	var servers []string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.SplitN(line, "#", 2)[0]
		line = strings.SplitN(line, ";", 2)[0]
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) != 2 || fields[0] != "nameserver" {
			return "", errors.New("native resolver backend required")
		}
		servers = append(servers, fields[1])
	}
	if len(servers) == 0 {
		return "", errNoUnderlay
	}
	if len(servers) != 1 {
		return "", errors.New("one captured resolver required")
	}
	ip := net.ParseIP(servers[0])
	if ip == nil || ip.To4() == nil || ip.IsLoopback() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsLinkLocalUnicast() || ip.Equal(net.IPv4bcast) {
		return "", errors.New("protected native resolver required")
	}
	return ip.String(), nil
}
func networkFacts() (dns, interfaces, identity string, err error) {
	return readNetworkFacts(false)
}
func (s *Service) networkFacts() (dns, interfaces, identity string, err error) {
	if s.resolver == nil {
		return networkFacts()
	}
	if err = s.resolver.Validate(s.ctx); err != nil {
		return
	}
	dns, interfaces, identity, err = readNetworkFacts(true)
	identity += "/" + s.resolver.Identity()
	return
}
func usesResolvedStub() bool {
	path, e := filepath.EvalSymlinks("/etc/resolv.conf")
	return e == nil && path == "/run/systemd/resolve/stub-resolv.conf"
}
func readNetworkFacts(resolved bool) (dns, interfaces, identity string, err error) {
	f, err := os.Open("/etc/resolv.conf")
	if err != nil {
		return
	}
	b, err := io.ReadAll(io.LimitReader(f, 16385))
	f.Close()
	if err != nil {
		return
	}
	if len(b) > 16384 {
		err = errors.New("resolver file too large")
		return
	}
	if resolved {
		if !usesResolvedStub() {
			err = errors.New("system resolver mode changed")
			return
		}
		servers := 0
		for _, line := range strings.Split(string(b), "\n") {
			f := strings.Fields(strings.SplitN(line, "#", 2)[0])
			if len(f) == 0 {
				continue
			}
			if f[0] == "nameserver" {
				if len(f) != 2 || f[1] != linuxresolver.Stub {
					err = errors.New("system stub address changed")
					return
				}
				servers++
			} else if f[0] != "search" && f[0] != "options" {
				err = errors.New("unsupported stub declaration")
				return
			}
		}
		if servers != 1 {
			err = errors.New("ambiguous system stub")
			return
		}
		dns = linuxresolver.Stub
	} else {
		dns, err = resolverAddress(b)
	}
	if err != nil {
		return
	}
	all, e := net.Interfaces()
	if e != nil {
		err = e
		return
	}
	var facts []map[string]any
	usableAddress := false
	for _, i := range all {
		a, e := i.Addrs()
		if e != nil {
			err = e
			return
		}
		addresses := make([]string, 0, len(a))
		for _, v := range a {
			addresses = append(addresses, v.String())
			if ip, _, parseErr := net.ParseCIDR(v.String()); parseErr == nil && i.Flags&net.FlagUp != 0 && ip.IsGlobalUnicast() {
				usableAddress = true
			}
		}
		facts = append(facts, map[string]any{"name": i.Name, "index": i.Index, "type": "other", "facts": map[string]any{"mtu": i.MTU, "flags": uint32(i.Flags), "addresses": addresses}})
	}
	if !usableAddress {
		err = errNoUnderlay
		return
	}
	data, e := json.Marshal(facts)
	if e != nil {
		err = e
		return
	}
	interfaces = string(data)
	hash := sha256.Sum256(append(append([]byte(dns), 0), data...))
	if resolved {
		hash = sha256.Sum256(append(append(b, 0), data...))
	}
	identity = hex.EncodeToString(hash[:])
	return
}

// RecoverState is an offline maintenance operation used after service stop.
// The same state lock excludes a live owner; nothing is installed or connected.
func RecoverState(root string) error {
	lock, e := linuxcapture.LockServiceDirectory(root)
	if e != nil {
		return e
	}
	defer lock.Close()
	return linuxcapture.Recover(filepath.Join(root, "capture"))
}
