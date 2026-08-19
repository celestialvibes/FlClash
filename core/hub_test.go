package main

import (
	"encoding/base64"
	"github.com/metacubex/mihomo/config"
	"testing"
)

func TestParseProfileConfigConvertsBase64Subscription(t *testing.T) {
	subscription := base64.StdEncoding.EncodeToString([]byte(
		"vless://a1b2c3d4-eacc-4433-981b-7e5f9a8b@192.0.2.1:443?encryption=none&security=reality&type=tcp&sni=example.com&fp=chrome&pbk=ppQ9FwLrLIa0AOrp1WvcyiaQ37vg2WSy_CD4bIdiTUw&sid=6ba85179f3a2b4c5&flow=xtls-rprx-vision#Amsterdam\n" +
			"hysteria2://password@example.com:443?sni=example.com#Paris\n",
	))

	rawConfig, err := parseProfileConfig([]byte(subscription))
	if err != nil {
		t.Fatal(err)
	}
	if len(rawConfig.Proxy) != 2 {
		t.Fatalf("got %d proxies, want 2", len(rawConfig.Proxy))
	}
	if len(rawConfig.ProxyGroup) != 1 || rawConfig.ProxyGroup[0]["name"] != "LOOM" {
		t.Fatalf("unexpected proxy groups: %#v", rawConfig.ProxyGroup)
	}
	if len(rawConfig.Rule) != 1 || rawConfig.Rule[0] != "MATCH,LOOM" {
		t.Fatalf("unexpected rules: %#v", rawConfig.Rule)
	}
	if _, err := config.ParseRawConfig(rawConfig); err != nil {
		t.Fatal(err)
	}
}
