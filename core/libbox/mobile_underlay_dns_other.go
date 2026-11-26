//go:build !darwin || !cgo

package libbox

import (
	"context"
	"time"

	mDNS "github.com/miekg/dns"
)

func mobileUnderlayUsesNativeScopedResolver() bool {
	return false
}

func darwinScopedDNSServiceLookup(
	_ context.Context,
	_ int,
	_ mDNS.Question,
	_ time.Duration,
) (underlayLookupResult, error) {
	return underlayLookupResult{}, errMobileUnderlayDNSUnavailable
}
