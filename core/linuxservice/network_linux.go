//go:build linux && !android

package linuxservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/fsnotify/fsnotify"
	"github.com/kafeifei/xdial/core/libbox"
	"github.com/vishvananda/netlink"
)

// Events invalidate captured DNS/interface facts. No timer polls the network,
// no interface is ranked, and no route decision is made here. The initial
// service withdraws stale capture before resuming the existing user intent.
func (s *Service) observeNetwork() error {
	w, e := fsnotify.NewWatcher()
	if e != nil {
		return e
	}
	s.watcher = w
	if e = s.watchResolver(); e != nil {
		return e
	}
	links := make(chan netlink.LinkUpdate, 32)
	addresses := make(chan netlink.AddrUpdate, 32)
	failed := make(chan struct{}, 1)
	failure := func(error) {
		select {
		case failed <- struct{}{}:
		default:
		}
	}
	if e = netlink.LinkSubscribeWithOptions(links, s.ctx.Done(), netlink.LinkSubscribeOptions{ErrorCallback: failure}); e != nil {
		return e
	}
	if e = netlink.AddrSubscribeWithOptions(addresses, s.ctx.Done(), netlink.AddrSubscribeOptions{ErrorCallback: failure}); e != nil {
		return e
	}
	s.observer.Add(1)
	go func() {
		defer s.observer.Done()
		for {
			broken := false
			select {
			case <-s.ctx.Done():
				return
			case _, ok := <-links:
				broken = !ok
			case _, ok := <-addresses:
				broken = !ok
			case event, ok := <-w.Events:
				broken = !ok
				if ok && event.Name == "/run/nscd" {
					if e := s.watchNSSCache(); e != nil {
						broken = true
					}
				}
			case <-w.Errors:
				broken = true
			case <-failed:
				broken = true
			}
			select {
			case <-s.ctx.Done():
				return
			case <-s.gate:
			}
			if broken {
				s.networkFailed = true
			}
			// Re-arm configuration chains after rename or symlink replacement.
			// Add watches before reading facts so the new target cannot change
			// unnoticed between admission and subscription.
			if !broken && s.watchResolver() != nil {
				broken = true
				s.networkFailed = true
			}
			if broken {
				if s.core != nil || s.profile != nil {
					s.revision++
					s.disconnect()
				}
			} else if s.core != nil {
				_, _, identity, err := s.networkFacts()
				switch {
				case resolverIngressReady() != nil || (err != nil && !errors.Is(err, errNoUnderlay)):
					s.revision++
					s.disconnect()
				case err != nil || identity != s.underlay:
					s.revision++
					if s.withdraw() != nil {
						s.cancelRecovery()
					} else {
						s.controller.ObserveUnderlay("")
						s.resume()
					}
				}
			} else {
				s.resume()
			}
			s.gate <- struct{}{}
			if broken {
				return
			}
		}
	}()
	return nil
}

func (s *Service) observeResolverLease() {
	l := s.resolver
	if l == nil {
		return
	}
	s.observer.Add(1)
	go func() {
		defer s.observer.Done()
		select {
		case <-s.ctx.Done():
			return
		case <-l.Invalid():
		}
		select {
		case <-s.ctx.Done():
			return
		case <-s.gate:
		}
		defer func() { s.gate <- struct{}{} }()
		if s.resolver == l {
			s.revision++
			s.disconnect()
		}
	}()
}
func (s *Service) watchResolver() error {
	if e := s.watcher.Add("/etc"); e != nil {
		return e
	}
	if e := s.watcher.Add("/run"); e != nil {
		return e
	}
	if e := s.watchNSSCache(); e != nil {
		return e
	}
	for _, path := range []string{"/etc/resolv.conf", "/etc/nsswitch.conf"} {
		if e := watchConfigPath(s.watcher, path); e != nil {
			return e
		}
	}
	return nil
}

// Fedora's nsswitch.conf can point into authselect. Observe every traversed
// parent, symlink and final inode, not just /etc or the final target directory.
// Watch-before-lstat also covers replacement while resolving the chain. Old
// watches are retained until service shutdown; bounded growth fails closed.
func watchConfigPath(w *fsnotify.Watcher, path string) error {
	if !filepath.IsAbs(path) {
		return errors.New("absolute configuration path required")
	}
	pending := strings.Split(strings.TrimPrefix(filepath.Clean(path), "/"), "/")
	parent := "/"
	links := 0
	add := func(path string) error {
		watches := w.WatchList()
		for _, existing := range watches {
			if existing == path {
				return nil
			}
		}
		if len(watches) >= 64 {
			return errors.New("configuration watch bound exceeded")
		}
		return w.Add(path)
	}
	for len(pending) > 0 {
		if e := add(parent); e != nil {
			return e
		}
		next := filepath.Join(parent, pending[0])
		pending = pending[1:]
		st, e := os.Lstat(next)
		if e != nil {
			return e
		}
		if st.Mode()&os.ModeSymlink != 0 {
			links++
			if links > 40 {
				return errors.New("configuration symlink bound exceeded")
			}
			target, e := os.Readlink(next)
			if e != nil {
				return e
			}
			if !filepath.IsAbs(target) {
				target = filepath.Join(parent, target)
			}
			pending = append(strings.Split(strings.TrimPrefix(filepath.Clean(target), "/"), "/"), pending...)
			parent = "/"
			continue
		}
		parent = next
	}
	return add(parent)
}

func (s *Service) watchNSSCache() error {
	if _, e := os.Stat("/run/nscd"); os.IsNotExist(e) {
		return nil
	} else if e != nil {
		return e
	}
	return s.watcher.Add("/run/nscd")
}

// Cancel only the preparation lease. Join the callback before committing so a
// late deadline callback cannot cancel an already published generation.
func (s *Service) prepare(ctx context.Context, l *libbox.Libbox, work func() error) error {
	local, cancel := context.WithCancel(ctx)
	stopService := context.AfterFunc(s.ctx, cancel)
	defer stopService()
	defer cancel()
	done := make(chan struct{})
	stop := context.AfterFunc(local, func() { defer close(done); l.CancelPreparation() })
	e := work()
	if !stop() {
		<-done
	}
	if e == nil {
		e = local.Err()
	}
	return e
}
