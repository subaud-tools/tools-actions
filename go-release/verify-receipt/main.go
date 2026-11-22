// verify-receipt checks a release receipt's signature with Go's standard
// Ed25519, the check the family's updater makes.
//
// Usage: verify-receipt KEY RECEIPT SIG
//
// KEY holds the base64 DER SubjectPublicKeyInfo (`aws kms get-public-key`),
// SIG the base64 signature over RECEIPT's exact bytes. Exit 0 only when the
// signature verifies.
package main

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"os"
	"strings"
)

func decode(path string) []byte {
	raw, err := os.ReadFile(path)
	if err != nil {
		fail(err)
	}
	out, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil {
		fail(fmt.Errorf("%s: %w", path, err))
	}
	return out
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "verify-receipt:", err)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 4 {
		fail(fmt.Errorf("usage: verify-receipt KEY RECEIPT SIG"))
	}
	parsed, err := x509.ParsePKIXPublicKey(decode(os.Args[1]))
	if err != nil {
		fail(err)
	}
	key, ok := parsed.(ed25519.PublicKey)
	if !ok {
		fail(fmt.Errorf("%s is not an Ed25519 public key", os.Args[1]))
	}
	receipt, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail(err)
	}
	if !ed25519.Verify(key, receipt, decode(os.Args[3])) {
		fail(fmt.Errorf("the signature in %s is not valid for %s", os.Args[3], os.Args[2]))
	}
}
