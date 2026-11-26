//go:build !darwin || !cgo

package libbox

import (
	"context"
	"time"
)

func mobileUnderlayUsesNativeScopedResolver() bool {
	return false
}

func darwinScopedDNSServiceLookup(
	_ context.Context,
	_ int,
	_ string,
	_ uint16,
	_ time.Duration,
) (underlayLookupResult, error) {
	return underlayLookupResult{}, errMobileUnderlayDNSUnavailable
}
