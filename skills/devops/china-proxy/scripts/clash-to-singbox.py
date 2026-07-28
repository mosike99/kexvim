#!/usr/bin/env python3
"""
clash-to-singbox.py — Convert a Clash-style proxy entry to a sing-box outbound.

Usage:
  python3 clash-to-singbox.py <clash-yaml-entry>

Input format (one-line YAML from Clash config):
  - { name: '🇯🇵 日本1', type: vmess, server: jp1.example.com, port: 443,
      uuid: xxx, alterId: 0, cipher: auto, udp: true, tls: true,
      skip-cert-verify: true, servername: gw.alicdn.com }

Output: sing-box JSON outbound entry
"""

import json
import sys
import yaml  # pip install pyyaml

def convert_clash_to_singbox(clash_entry: dict) -> dict:
    """Convert a single Clash proxy entry to sing-box outbound format."""

    proxy_type = clash_entry.get("type", "vmess")
    if proxy_type != "vmess":
        print(f"Warning: {proxy_type} not fully tested; use at your own risk.", file=sys.stderr)

    outbound = {
        "type": proxy_type,
        "tag": clash_entry.get("name", "proxy"),
        "server": clash_entry["server"],
        "server_port": clash_entry["port"],
    }

    if proxy_type == "vmess":
        outbound["uuid"] = clash_entry["uuid"]
        outbound["security"] = clash_entry.get("cipher", "auto")
        outbound["alter_id"] = clash_entry.get("alterId", 0)

    if clash_entry.get("tls"):
        outbound["tls"] = {
            "enabled": True,
            "server_name": clash_entry.get("servername", clash_entry["server"]),
            "insecure": clash_entry.get("skip-cert-verify", False),
        }

    return outbound


if __name__ == "__main__":
    # Read from stdin as YAML list item
    data = yaml.safe_load(sys.stdin.read())
    if isinstance(data, dict):
        data = [data]
    for entry in data:
        sb = convert_clash_to_singbox(entry)
        print(json.dumps(sb, indent=2))
