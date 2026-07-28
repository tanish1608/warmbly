package kms

import "testing"

func TestValidateGCPKeyName(t *testing.T) {
	good := "projects/p/locations/us-central1/keyRings/r/cryptoKeys/k"
	if err := validateGCPKeyName(good); err != nil {
		t.Fatalf("valid key name rejected: %v", err)
	}

	for _, bad := range []string{
		"",
		"projects/p/locations/l/keyRings/r", // truncated
		"projects/p/locations/l/keyRings/r/cryptoKeys/k/cryptoKeyVersions/1", // version, not key
		"project/p/locations/l/keyRings/r/cryptoKeys/k",                      // typo in literal
		"alias/warmbly",
	} {
		if err := validateGCPKeyName(bad); err == nil {
			t.Fatalf("expected %q to be rejected", bad)
		}
	}
}

func TestNewGCPFromEnv_AssemblesKeyNameFromParts(t *testing.T) {
	// Only the name assembly and validation are exercised: constructing the
	// client needs real GCP credentials, so a failure past validation is fine.
	t.Setenv("KMS_GCP_KEY_NAME", "")
	t.Setenv("GCP_PROJECT_ID", "")
	t.Setenv("KMS_GCP_KEY_RING", "warmbly")
	t.Setenv("KMS_GCP_KEY_ID", "root")

	if _, err := NewGCPFromEnv(t.Context()); err == nil {
		t.Fatal("expected error when GCP_PROJECT_ID is unset")
	}
}

func TestNewGCP_RejectsMalformedKeyName(t *testing.T) {
	if _, err := NewGCP(t.Context(), "not-a-key-name"); err == nil {
		t.Fatal("expected malformed key name to be rejected before client construction")
	}
}

func TestCRC32C(t *testing.T) {
	// Castagnoli check value for the standard "123456789" vector.
	if got := crc32c([]byte("123456789")); got != 0xE3069283 {
		t.Fatalf("crc32c mismatch: got %#x", got)
	}
}
