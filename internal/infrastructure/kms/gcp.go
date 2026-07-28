package kms

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"strings"

	gkms "cloud.google.com/go/kms/apiv1"
	"cloud.google.com/go/kms/apiv1/kmspb"
	"google.golang.org/protobuf/types/known/wrapperspb"
)

// GCPProvider implements Provider on top of Google Cloud KMS.
//
// Cloud KMS has no GenerateDataKey primitive, so the DEK is generated locally
// with crypto/rand and wrapped by a Cloud KMS Encrypt call. The stored blob is
// the raw Cloud KMS ciphertext, base64-encoded.
//
// Ciphertext produced here is only readable by the same crypto key, and Cloud
// KMS ciphertext is not interchangeable with the local or AWS providers.
type GCPProvider struct {
	client  *gkms.KeyManagementClient
	keyName string
}

var crc32cTable = crc32.MakeTable(crc32.Castagnoli)

// NewGCP builds a provider bound to a Cloud KMS crypto key. keyName is the full
// resource name: projects/P/locations/L/keyRings/R/cryptoKeys/K
func NewGCP(ctx context.Context, keyName string) (*GCPProvider, error) {
	if err := validateGCPKeyName(keyName); err != nil {
		return nil, err
	}
	client, err := gkms.NewKeyManagementClient(ctx)
	if err != nil {
		return nil, fmt.Errorf("gcp kms: new client: %w", err)
	}
	return &GCPProvider{client: client, keyName: keyName}, nil
}

// NewGCPFromEnv reads KMS_GCP_KEY_NAME. If only KMS_GCP_KEY_RING and
// KMS_GCP_KEY_ID are set, the name is assembled from GCP_PROJECT_ID and
// KMS_GCP_LOCATION (default "global").
func NewGCPFromEnv(ctx context.Context) (*GCPProvider, error) {
	name := os.Getenv("KMS_GCP_KEY_NAME")
	if name == "" {
		project := os.Getenv("GCP_PROJECT_ID")
		ring := os.Getenv("KMS_GCP_KEY_RING")
		key := os.Getenv("KMS_GCP_KEY_ID")
		if project == "" || ring == "" || key == "" {
			return nil, errors.New("gcp kms: set KMS_GCP_KEY_NAME, or GCP_PROJECT_ID + KMS_GCP_KEY_RING + KMS_GCP_KEY_ID")
		}
		location := os.Getenv("KMS_GCP_LOCATION")
		if location == "" {
			location = "global"
		}
		name = fmt.Sprintf("projects/%s/locations/%s/keyRings/%s/cryptoKeys/%s", project, location, ring, key)
	}
	return NewGCP(ctx, name)
}

func validateGCPKeyName(name string) error {
	parts := strings.Split(name, "/")
	if len(parts) != 8 || parts[0] != "projects" || parts[2] != "locations" || parts[4] != "keyRings" || parts[6] != "cryptoKeys" {
		return fmt.Errorf("gcp kms: key name must be projects/P/locations/L/keyRings/R/cryptoKeys/K, got %q", name)
	}
	return nil
}

func (p *GCPProvider) Name() string { return "gcp-kms" }

// Close releases the underlying gRPC connection.
func (p *GCPProvider) Close() error { return p.client.Close() }

func (p *GCPProvider) GenerateDataKey(ctx context.Context) ([]byte, string, error) {
	dek := make([]byte, 32) // AES-256
	if _, err := io.ReadFull(rand.Reader, dek); err != nil {
		return nil, "", err
	}
	// Cloud KMS verifies the request CRC and reports back whether it checked,
	// which is the only way to catch corruption on the wire.
	resp, err := p.client.Encrypt(ctx, &kmspb.EncryptRequest{
		Name:            p.keyName,
		Plaintext:       dek,
		PlaintextCrc32C: wrapperspb.Int64(crc32c(dek)),
	})
	if err != nil {
		return nil, "", fmt.Errorf("gcp kms: encrypt data key: %w", err)
	}
	if !resp.VerifiedPlaintextCrc32C {
		return nil, "", errors.New("gcp kms: encrypt request corrupted in transit")
	}
	if resp.CiphertextCrc32C.GetValue() != crc32c(resp.Ciphertext) {
		return nil, "", errors.New("gcp kms: encrypt response corrupted in transit")
	}
	return dek, base64.StdEncoding.EncodeToString(resp.Ciphertext), nil
}

func (p *GCPProvider) GetDecryptedKey(ctx context.Context, ciphertextB64 string) ([]byte, error) {
	blob, err := base64.StdEncoding.DecodeString(ciphertextB64)
	if err != nil {
		return nil, fmt.Errorf("gcp kms: decode ciphertext: %w", err)
	}
	resp, err := p.client.Decrypt(ctx, &kmspb.DecryptRequest{
		Name:             p.keyName,
		Ciphertext:       blob,
		CiphertextCrc32C: wrapperspb.Int64(crc32c(blob)),
	})
	if err != nil {
		return nil, fmt.Errorf("gcp kms: decrypt data key: %w", err)
	}
	if resp.PlaintextCrc32C.GetValue() != crc32c(resp.Plaintext) {
		return nil, errors.New("gcp kms: decrypt response corrupted in transit")
	}
	return resp.Plaintext, nil
}

func crc32c(b []byte) int64 { return int64(crc32.Checksum(b, crc32cTable)) }
