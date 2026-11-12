// SPDX-License-Identifier: GPL-3.0-or-later
// Supervises Mihomo as the owning GUI user. Never parse profiles or run a proxy as root.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

func normalize(data []byte, port int, tunnelInterface string) ([]byte, error) {
	if len(data) == 0 || len(data) > 5*1024*1024 {
		return nil, errors.New("profile size invalid")
	}
	if port < 1024 || port > 65535 {
		return nil, errors.New("proxy port invalid")
	}
	if !regexp.MustCompile(`^utun[0-9]+$`).MatchString(tunnelInterface) {
		return nil, errors.New("WireGuard tunnel interface required")
	}
	var profile map[string]interface{}
	if err := yaml.Unmarshal(data, &profile); err != nil || profile == nil {
		return nil, errors.New("profile YAML invalid")
	}
	// A profile cannot install a second TUN, bind a physical interface, open an
	// API or LAN listener, or replace the WireGuard tunnel's DNS settings.
	for key, value := range map[string]interface{}{
		"port": 0, "socks-port": 0, "redir-port": 0, "tproxy-port": 0,
		"mixed-port": port, "allow-lan": false, "bind-address": "127.0.0.1",
		"external-controller": "", "external-controller-tls": "",
		"external-controller-unix": "", "external-controller-pipe": "",
		"listeners": []interface{}{}, "tunnels": []interface{}{},
		"tun":            map[string]interface{}{"enable": false},
		"dns":            map[string]interface{}{"enable": false},
		"authentication": []interface{}{}, "find-process-mode": "off",
		"external-ui": "", "external-ui-url": "", "log-level": "silent",
		"ss-config": "", "vmess-config": "",
		"tuic-server": map[string]interface{}{"enable": false},
	} {
		profile[key] = value
	}
	if _, exists := profile["mode"]; !exists {
		profile["mode"] = "rule"
	}
	removeRouteBindings(profile)
	// The interface comes from WireGuardAdapter, never from imported YAML.
	profile["interface-name"] = tunnelInterface
	return json.Marshal(profile)
}

func removeRouteBindings(value interface{}) {
	switch value := value.(type) {
	case map[string]interface{}:
		delete(value, "interface-name")
		delete(value, "routing-mark")
		for _, child := range value {
			removeRouteBindings(child)
		}
	case []interface{}:
		for _, child := range value {
			removeRouteBindings(child)
		}
	}
}

func run() error {
	profilePath := flag.String("profile", "", "local YAML profile")
	directory := flag.String("directory", "", "private runtime directory")
	core := flag.String("core", "", "bundled Mihomo executable")
	port := flag.Int("port", 17890, "loopback mixed port")
	tunnelInterface := flag.String("interface", "", "WireGuard utun interface")
	check := flag.Bool("check", false, "validate profile syntax without starting")
	uid := flag.Int("uid", os.Getuid(), "owning user's UID")
	gid := flag.Int("gid", os.Getgid(), "owning user's primary GID")
	worker := flag.Bool("worker", false, "internal unprivileged worker")
	flag.Parse()
	if os.Geteuid() == 0 {
		if *worker || *uid < 501 || *uid >= 2147483647 || *gid < 0 || *gid >= 2147483647 {
			return errors.New("unprivileged owner required")
		}
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		// Credential switching happens in fork/exec, before the child Go runtime.
		// The root supervisor never opens any caller-writable profile or path.
		child := exec.Command(executable, append(os.Args[1:], "-worker")...)
		child.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{
			Uid: uint32(*uid), Gid: uint32(*gid), Groups: []uint32{uint32(*gid)},
		}}
		child.Dir = "/"
		child.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + *directory, "TMPDIR=" + *directory}
		return supervise(child)
	}
	if *uid != os.Geteuid() || *gid != os.Getegid() {
		return errors.New("owner does not match process credentials")
	}
	data, err := os.ReadFile(*profilePath)
	if err != nil {
		return errors.New("cannot read profile")
	}
	config, err := normalize(data, *port, *tunnelInterface)
	if err != nil || *check {
		return err
	}
	if !filepath.IsAbs(*core) || !filepath.IsAbs(*directory) {
		return errors.New("absolute runtime paths required")
	}
	// Fail before Mihomo starts if this port belongs to another application.
	listener, err := net.Listen("tcp4", net.JoinHostPort("127.0.0.1", strconv.Itoa(*port)))
	if err != nil {
		return errors.New("proxy port already in use")
	}
	listener.Close()
	if err := os.MkdirAll(*directory, 0700); err != nil {
		return err
	}
	configPath := filepath.Join(*directory, "runtime.json")
	if err := os.WriteFile(configPath, config, 0600); err != nil {
		return err
	}
	defer os.Remove(configPath)
	cmd := exec.Command(*core, "-d", *directory, "-f", configPath)
	cmd.Dir = *directory
	return supervise(cmd)
}

func supervise(cmd *exec.Cmd) error {
	// Do not expose node credentials or remote subscription URLs in diagnostics.
	if err := cmd.Start(); err != nil {
		return errors.New("cannot start supervised process")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	parent := os.Getppid()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	stop := func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	}
	for {
		select {
		case err := <-done:
			if err != nil {
				return errors.New("proxy core exited")
			}
			return nil
		case <-signals:
			stop()
			return nil
		case <-ticker.C:
			// A provider crash must not leave a proxy process listening forever.
			if os.Getppid() != parent || parent == 1 {
				stop()
				return nil
			}
		}
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
