# Linux Tunnel, VPN, and iptables Cheatsheet

Private command reference for class and lab work:

- IPIP tunnels
- SSH local/remote/dynamic forwards
- OpenVPN
- WireGuard
- iptables (idempotent add/check/own-chain)
- sysctl, policy routing, netns

**Start here:** [CHEATSHEET.md](./CHEATSHEET.md)

**AP peer generator:** [scripts/wg-ap-peer.sh](./scripts/wg-ap-peer.sh) — generate WireGuard keys on the AP against an existing MikroTik WG interface. Endpoint is the router. The only value copied off the router is its public key.

Repo is private so lab addressing and key-handling notes stay off the public internet. Do not commit private keys, `.ovpn` embeds, or live `iptables-save` dumps.
