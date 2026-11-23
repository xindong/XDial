//go:build linux && !android

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/kafeifei/xdial/core/controlpipe"
	"github.com/kafeifei/xdial/core/linuxcapture"
	"github.com/kafeifei/xdial/core/linuxinstall"
	"github.com/kafeifei/xdial/core/linuxservice"
	"io"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
func run() error {
	if len(os.Args) < 2 {
		return fmt.Errorf("usage: xdial-service serve|status|connect|switch|disconnect")
	}
	op := os.Args[1]
	if op == "upgrade" || op == "recover-upgrade" {
		f := flag.NewFlagSet(op, flag.ContinueOnError)
		bundle := f.String("bundle", "", "root-owned reviewed bundle directory")
		if e := f.Parse(os.Args[2:]); e != nil {
			return e
		}
		if f.NArg() != 0 {
			return fmt.Errorf("unexpected argument")
		}
		if op == "recover-upgrade" {
			if *bundle != "" {
				return fmt.Errorf("recovery does not accept a bundle")
			}
			return linuxinstall.Recover()
		}
		return linuxinstall.Upgrade(*bundle)
	}
	if op == "validate-policy" {
		if len(os.Args) != 8 {
			return fmt.Errorf("expected UID CAPTURE_BIT BYPASS_BIT TABLE PRIORITY LISTENER")
		}
		marks := make([]uint32, 3)
		for i := range marks {
			n, e := strconv.ParseUint(os.Args[i+2], 0, 32)
			if e != nil {
				return fmt.Errorf("invalid policy number")
			}
			marks[i] = uint32(n)
		}
		// Table and priority are non-negative kernel int32 values.
		routing := make([]int, 2)
		for i := range routing {
			n, e := strconv.ParseInt(os.Args[i+5], 0, 32)
			if e != nil || n < 0 {
				return fmt.Errorf("invalid policy number")
			}
			routing[i] = int(n)
		}
		p := linuxservice.Policy{Version: 1, AllowedUID: marks[0], Socket: "/run/xdial-service/control.sock", Capture: linuxcapture.Plan{CaptureMark: marks[1], BypassMark: marks[2], Table: routing[0], Priority: routing[1], Listener: os.Args[7]}}
		if p.AllowedUID == 0 {
			return fmt.Errorf("select one unprivileged UID")
		}
		if e := p.Capture.Validate(); e != nil {
			return e
		}
		return json.NewEncoder(os.Stdout).Encode(p)
	}
	flags := flag.NewFlagSet(op, flag.ContinueOnError)
	state := flags.String("state", "/var/lib/xdial-service", "installer-owned service state directory")
	socket := flags.String("socket", "/run/xdial-service/control.sock", "installed control socket")
	instance := flags.String("instance", "", "expected service instance from status")
	revision := flags.Uint64("revision", 0, "expected status revision")
	if e := flags.Parse(os.Args[2:]); e != nil {
		return e
	}
	if flags.NArg() != 0 {
		return fmt.Errorf("unexpected argument")
	}
	if op == "recover" {
		return linuxservice.RecoverState(*state)
	}
	if op == "serve" {
		s, e := linuxservice.Open(*state)
		if e != nil {
			return fmt.Errorf("service startup rejected: %w", e)
		}
		if e = notifyReady(); e != nil {
			s.Close()
			return fmt.Errorf("service readiness notification failed: %w", e)
		}
		ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer cancel()
		<-ctx.Done()
		return s.Close()
	}
	if op != "status" && op != "connect" && op != "switch" && op != "disconnect" {
		return fmt.Errorf("unknown operation")
	}
	var payload []byte
	if op != "status" {
		m := linuxservice.Mutation{ExpectedInstance: *instance, ExpectedRevision: *revision}
		if op != "disconnect" {
			b, e := io.ReadAll(io.LimitReader(os.Stdin, controlpipe.MaxFrame))
			if e != nil {
				return e
			}
			if len(b) >= controlpipe.MaxFrame {
				return fmt.Errorf("profile exceeds control limit")
			}
			m.Profile = b
		}
		var e error
		payload, e = json.Marshal(m)
		if e != nil {
			return fmt.Errorf("invalid Profile JSON")
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	response, e := controlpipe.CallUnix(ctx, *socket, 0, controlpipe.Request{Operation: op, Payload: payload})
	if e != nil {
		return fmt.Errorf("control request failed: %w", e)
	}
	if e = json.NewEncoder(os.Stdout).Encode(response); e != nil {
		return e
	}
	if response.Code != "ok" && response.Code != "waiting_network" {
		return fmt.Errorf("%s", response.Code)
	}
	return nil
}
