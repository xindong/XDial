package libbox

import (
	"testing"
	"time"
)

// The app tells users exactly what the My Server test requests and how much it
// downloads (apple/CloudHost/CloudHostDisclosure.swift). Changing any of these
// values must update that text and the data use notice.
func TestCloudHostTestMatchesTheDisclosure(t *testing.T) {
	if lineLatencyTestURL != "https://www.gstatic.com/generate_204" ||
		exitTraceURL != "https://1.1.1.1/cdn-cgi/trace" ||
		throughputURL != "https://speed.cloudflare.com/__down?bytes=10000000" ||
		throughputLimit != 12*time.Second {
		t.Fatal("the My Server test changed; update CloudHostDisclosure and the data use notice")
	}
}
