package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestBundledMihomoAcceptsNormalizedDirectProfile(t *testing.T) {
	binary := os.Getenv("MIHOMO_BINARY")
	if binary == "" {
		t.Skip("set MIHOMO_BINARY after building the runtime")
	}
	profile, err := normalize([]byte("mode: rule\nrules:\n  - MATCH,DIRECT\n"), 17890, "utun9999")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "config.json")
	if err := os.WriteFile(path, profile, 0600); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(binary, "-t", "-d", directory, "-f", path).CombinedOutput()
	if err != nil {
		t.Fatalf("Mihomo rejected normalized profile: %v: %s", err, output)
	}
}

func TestProfileCannotReplaceWireGuardRouteOrExposeListeners(t *testing.T) {
	input := []byte(`
mixed-port: 7890
allow-lan: true
external-controller: 0.0.0.0:9090
interface-name: en0
tun: {enable: true, auto-route: true}
dns: {enable: true, listen: "0.0.0.0:53"}
listeners: [{name: unsafe, type: socks, port: 9999}]
proxies:
  - {name: demo, type: socks5, server: example.com, port: 1080, interface-name: en0}
rules: [MATCH,DIRECT]
`)
	output, err := normalize(input, 17890, "utun12")
	if err != nil {
		t.Fatal(err)
	}
	var profile map[string]interface{}
	if err := json.Unmarshal(output, &profile); err != nil {
		t.Fatal(err)
	}
	if profile["mixed-port"] != float64(17890) || profile["allow-lan"] != false ||
		profile["external-controller"] != "" || profile["interface-name"] != "utun12" {
		t.Fatalf("unsafe profile: %s", output)
	}
	for _, key := range []string{"tun", "dns"} {
		if profile[key].(map[string]interface{})["enable"] != false {
			t.Fatal(key)
		}
	}
	node := profile["proxies"].([]interface{})[0].(map[string]interface{})
	if node["interface-name"] != nil || node["server"] != "example.com" {
		t.Fatal(node)
	}
	if len(profile["listeners"].([]interface{})) != 0 {
		t.Fatal("extra listener")
	}
}

func TestMalformedProfileAndPrivilegedPortFail(t *testing.T) {
	for _, input := range []string{"", "[]", "a: [", "a: 1\na: 2"} {
		if _, err := normalize([]byte(input), 17890, "utun12"); err == nil {
			t.Fatal(input)
		}
	}
	if _, err := normalize([]byte("mode: rule"), 53, "utun12"); err == nil {
		t.Fatal("port accepted")
	}
	if _, err := normalize([]byte("mode: rule"), 17890, "en0"); err == nil {
		t.Fatal("physical interface accepted")
	}
}
