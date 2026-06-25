package main

import (
	"os"
	"path/filepath"
	"testing"
)

// Round-trip safety: parsing a .env then writing it back (simulating "accept every
// prefilled value") must preserve EVERY key=value pair — no secret may be lost or
// mangled. This guards the most dangerous path: re-running setup on a populated .env.
func TestEnvRoundTripPreservesAllKeys(t *testing.T) {
	src := filepath.Join("..", "..", ".env")
	orig, err := os.ReadFile(src)
	if err != nil {
		t.Skip("no real .env to test against:", err)
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, ".env"), orig, 0o600); err != nil {
		t.Fatal(err)
	}

	before := parseEnv(dir)
	// simulate the wizard: collect = whatever is already there (user accepts each prefill)
	values := map[string]string{}
	for _, s := range steps {
		values[s.key] = before[s.key]
	}
	if err := writeEnv(dir, values, before); err != nil {
		t.Fatal(err)
	}
	after := parseEnv(dir)

	for k, v := range before {
		if after[k] != v {
			t.Errorf("key %q changed: before=%q after=%q", k, v, after[k])
		}
	}
	if len(after) < len(before) {
		t.Errorf("lost keys: before=%d after=%d", len(before), len(after))
	}
}

// A fresh clone (no .env) must produce a .env seeded from .env.example with the values entered.
func TestEnvCreatedFromExample(t *testing.T) {
	dir := t.TempDir()
	if b, err := os.ReadFile(filepath.Join("..", "..", ".env.example")); err == nil {
		_ = os.WriteFile(filepath.Join(dir, ".env.example"), b, 0o600)
	}
	values := map[string]string{"PLAYIT_SECRET_KEY": "abc123", "LEVEL_NAME": "My World", "NTFY_TOPIC": "mc-test-xyz"}
	if err := writeEnv(dir, values, map[string]string{}); err != nil {
		t.Fatal(err)
	}
	got := parseEnv(dir)
	if got["PLAYIT_SECRET_KEY"] != "abc123" {
		t.Errorf("playit key not written: %q", got["PLAYIT_SECRET_KEY"])
	}
	if got["LEVEL_NAME"] != "My World" {
		t.Errorf("quoted value with space not round-tripped: %q", got["LEVEL_NAME"])
	}
}
