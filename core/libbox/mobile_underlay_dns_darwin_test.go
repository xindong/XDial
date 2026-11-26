//go:build darwin && cgo

package libbox

import (
	"encoding/binary"
	"encoding/hex"
	"testing"

	mDNS "github.com/miekg/dns"
)

func TestUnpackUnderlayDNSRecords(t *testing.T) {
	// Two callback frames (CNAME and HTTPS) can have different owners and TTLs.
	const alias = "alias.example."
	const target = "service.example."
	cnameRdata, err := hex.DecodeString("0773657276696365076578616d706c6500")
	if err != nil {
		t.Fatal(err)
	}
	httpsRdata, err := hex.DecodeString("00010000010003026832")
	if err != nil {
		t.Fatal(err)
	}
	var framed []byte
	for _, record := range []struct {
		owner  string
		rrType uint16
		ttl    uint32
		rdata  []byte
	}{
		{alias, mDNS.TypeCNAME, 20, cnameRdata},
		{target, mDNS.TypeHTTPS, 90, httpsRdata},
	} {
		framed = binary.BigEndian.AppendUint16(framed, uint16(len(record.owner)))
		framed = binary.BigEndian.AppendUint16(framed, record.rrType)
		framed = binary.BigEndian.AppendUint16(framed, mDNS.ClassINET)
		framed = binary.BigEndian.AppendUint16(framed, uint16(len(record.rdata)))
		framed = binary.BigEndian.AppendUint32(framed, record.ttl)
		framed = append(framed, record.owner...)
		framed = append(framed, record.rdata...)
	}

	records, err := unpackUnderlayDNSRecords(framed)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 ||
		records[0].String() != "alias.example.\t20\tIN\tCNAME\tservice.example." ||
		records[1].String() != "service.example.\t90\tIN\tHTTPS\t1 . alpn=\"h2\"" {
		t.Fatalf("decoded unexpected records: %v", records)
	}
	if _, err := unpackUnderlayDNSRecords(framed[:len(framed)-1]); err == nil {
		t.Fatal("accepted a truncated record")
	}
}
