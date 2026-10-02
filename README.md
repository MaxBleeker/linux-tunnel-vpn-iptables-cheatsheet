# linux-tunnel-vpn-iptables-cheatsheet
Command cheatsheet for IPIP, SSH tunnels, OpenVPN, WireGuard, and iptables automation.

## Bash ops reference

- [bash-ops-reference.md](bash-ops-reference.md) is the small set of bash used to script downloads, iptables reloads, file drops, and an nginx reverse proxy without a giant case block.
- [remote-exec.md](remote-exec.md) is the remote half: SSH wrappers, quoting, multiplexing, iptables over SSH with an undo timer, Docker, a systemd unit for a lab binary, and a Tiny SHell client wrapper that uses the same shape.

Each section is a copy-paste pattern plus a line-by-line note. Secrets stay in the environment. `conf/*.env` is gitignored.
