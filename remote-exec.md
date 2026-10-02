# Remote exec reference

How to send commands to remote lab hosts without a case block per tool. Covers SSH, Docker, iptables, and a small remote-shell client such as Tiny SHell (`tsh`). Same helper either way. The transport changes. The script does not.

This is for hosts you administer: your Kali box, a redirector, a lab VM. It is not a guide to planting a backdoor, hiding a process name, or building a connect-back implant. If the course tool is `tsh` instead of `ssh`, section 8 is the wrapper. The secret stays in the environment, not in the script.

Run any of these twice. Second run should change nothing and exit 0.

See the attached copy in chat if this file and the local one ever drift. The patterns below are the whole remote half.

## The one idea

One wrapper. Quoted heredoc. Values passed as `$1`. Docker, iptables, and `tsh` all call that wrapper. A new tool is not a new case.

```bash
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

ssh_run() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "$host" -- "$@"
}

ssh_bash() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "$host" bash -seuo pipefail -- "$@"
}

ssh_sudo() {
  local host="$1"; shift
  ssh "${SSH_OPTS[@]}" "$host" sudo -n bash -seuo pipefail -- "$@"
}

tsh_run() {
  local host="$1"; shift
  : "${TSH_SECRET:?set TSH_SECRET}"
  command -v tsh >/dev/null || { echo "missing tsh" >&2; exit 1; }
  tsh "$host" "$*"
}
```

| Piece | Meaning |
| --- | --- |
| `SSH_OPTS=(...)` | Array. Each option stays one argument. |
| `"${SSH_OPTS[@]}"` | Expand the array, one word per element. Quotes and `[@]` both required. |
| `--` | Rest is the remote command, even if it starts with `-`. |
| `bash -s` | Remote bash reads the script from stdin. |
| `sudo -n` | Fail instead of prompting. A prompt hangs the script. |
| `tsh_run` | Same shape as `ssh_run`. Secret from the environment, never the script. |

Which form:

| You need | Use |
| --- | --- |
| One command, no shell syntax | `ssh_run host -- systemctl reload nginx` |
| Several lines, pipes, if | `ssh_bash host <<'REMOTE'` |
| Root on the far side | `ssh_sudo host <<'REMOTE'` |
| A file you already wrote | `ssh host 'bash -s' < local-script.sh` |
| Copy a tree, then run | `rsync`, then `ssh_run` |
| Course client instead of ssh | `tsh_run host 'uname -a'` |

Do not build the remote command as a string. Word-splitting eats it. Pass arguments, or send a script.

## Quoting

Quote the heredoc tag. Pass the one local value as an argument.

```bash
port="${1:?need a port}"
ssh_bash user@box "$port" <<'REMOTE'
set -euo pipefail
port="$1"
ss -lntup | grep -w "$port" || echo "nothing on $port"
REMOTE
```

`'REMOTE'` means the local shell does not expand `$`. The remote bash does. Unquoting `<<REMOTE` to sneak a variable in works once, then eats the next legitimate `$`.

`printf %q` is the escape hatch when a tool only accepts a string. Use it for one value, not a whole script.

```bash
quoted="$(printf '%q' "$port")"
ssh_run user@box -- "ss -lnt | grep -w $quoted"
```

## Multiplexing

In `~/.ssh/config`, not in the script. First call opens the connection. The next ones reuse it for 10 minutes. This is the speed win.

```text
Host redir
    HostName 203.0.113.10
    User root
    IdentityFile ~/.ssh/lab_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

`ssh -O exit redir` closes it. `ControlPath` must be on a filesystem you own.

## Copy, then run

Stdin is for scripts under about 50 lines. A binary, a cert, a compose file: copy, then a short command.

```bash
rsync -a --checksum "$src" "$host:$dest"
rsync -a "$HOME/tools/" "$host:/opt/tools/"
```

Trailing slash on the source means contents, not the directory itself. `tools/` and `tools` are different. `--checksum` when you overwrite in place and the mtime is lying.

## iptables over SSH

Never `iptables -F` over SSH. Arm an undo, load a rules file, prove SSH still works, disarm.

```bash
ssh_sudo user@box <<'REMOTE'
set -euo pipefail
nohup bash -c 'sleep 120; iptables-restore < /root/fw-known-good.rules' >/tmp/fw-undo.log 2>&1 &
echo $! > /tmp/fw-undo.pid
REMOTE

ssh "${SSH_OPTS[@]}" user@box 'sudo -n iptables-restore' < conf/fw-redirector.rules
ssh_run user@box -- true

ssh_sudo user@box <<'REMOTE'
set -euo pipefail
if [[ -f /tmp/fw-undo.pid ]]; then
  kill "$(cat /tmp/fw-undo.pid)" 2>/dev/null || true
  rm -f /tmp/fw-undo.pid
fi
REMOTE
```

Open a second SSH session the first time you do this. The timer is the backup, not the plan. Rules differ by file (`fw-redirector.rules`, `fw-student.rules`), not by an `if` on the hostname.

A redirector forward is a rules file, not a chain of `-A`:

```text
*nat
:PREROUTING ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A PREROUTING -p tcp --dport 443 -j DNAT --to-destination 10.10.14.20:8443
-A POSTROUTING -p tcp -d 10.10.14.20 --dport 8443 -j MASQUERADE
COMMIT
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -p tcp --dport 8443 -d 10.10.14.20 -j ACCEPT
COMMIT
```

`ip_forward` is a sysctl, not an iptables rule:

```bash
ssh_sudo user@box <<'REMOTE'
set -euo pipefail
sysctl -w net.ipv4.ip_forward=1
printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-lab-forward.conf
REMOTE
```

## Docker

Prefer the client on Kali talking to the remote daemon. Unset it when done, or the next local `docker ps` hits the lab box.

```bash
export DOCKER_HOST="ssh://user@redir"
docker compose -f compose/lab.yml up -d
unset DOCKER_HOST
```

Or run the CLI on the far side, when the compose file already lives there:

```bash
ssh_bash user@box <<'REMOTE'
set -euo pipefail
cd /opt/lab
docker compose up -d
docker compose ps
REMOTE
```

`docker run` is not idempotent. Check, then start.

```bash
ssh_bash user@box <<'REMOTE'
set -euo pipefail
name=lab-nginx
if ! docker inspect "$name" >/dev/null 2>&1; then
  docker run -d --name "$name" --restart unless-stopped -p 8080:80 nginx:1.27
else
  docker start "$name" >/dev/null
fi
REMOTE
```

Do not `docker exec` a growing list of setup commands. That is the case block coming back. Pin the tag. Do not use `latest`.

## A long-running lab binary

A listener or proxy on your redirector is a systemd unit, not a `nohup` you will lose. One template, values from an env file. A second tool is a second env file.

```ini
[Service]
ExecStart=${BIN} ${ARGS}
Restart=on-failure
User=${RUN_USER}
WorkingDirectory=${WORKDIR}
NoNewPrivileges=true
```

```bash
ssh_sudo "$host" -- "$name" <<'REMOTE'
set -euo pipefail
name="$1"
install -m 644 "/tmp/$name.service" "/etc/systemd/system/$name.service"
systemctl daemon-reload
systemctl enable --now "$name"
REMOTE
```

Do not commit the secret. `conf/*.env` is gitignored. The unit does not hide the process name and does not phone home.

## tsh is the same shape

```bash
tsh_run 10.10.0.5 'uname -a'
```

File copy stays a client feature, wrapped the same way: `tsh "$host" get "$remote" "$local"`.

If one job must run over SSH on the redirector and over `tsh` on a lab target, pass the function. Do not case on the transport.

```bash
run_uname() {
  local transport="$1" host="$2"
  "$transport" "$host" 'uname -a'
}
run_uname ssh_run user@redir
run_uname tsh_run 10.10.0.5
```

## Many hosts

`conf/hosts.txt` is `alias` and `user@host`. Loop it. A host that needs different rules gets `conf/fw-$alias.rules`. Look the file up. Do not branch.

```bash
failed=()
while read -r alias target _; do
  [[ -z "${alias:-}" || "$alias" == \#* ]] && continue
  if ! cmd_fw_remote "$target" "conf/fw-$alias.rules"; then
    failed+=("$alias")
  fi
done < "$ROOT/conf/hosts.txt"
(( ${#failed[@]} == 0 )) || { echo "failed: ${failed[*]}" >&2; exit 1; }
```

An `if` on a capability is allowed (`apt-get` vs `dnf`). An `if` on the hostname is not. `DEBIAN_FRONTEND=noninteractive` stops apt asking a question the script cannot answer.

## Failures worth memorizing

| Symptom | Cause | Fix |
| --- | --- | --- |
| Hangs, no output | sudo wants a password, or ssh wants a host key | `sudo -n`, `BatchMode=yes`, accept the key once by hand |
| Remote `$host` empty | Heredoc unquoted, local shell ate it | Pass values as `$1`, keep `<<'REMOTE'` |
| iptables works by hand, fails in script | Not root, or `-F` duplicated rules | `ssh_sudo`, `iptables-restore` a file |
| Second `docker run` errors | Container already exists | `inspect` then `start`, or compose |
| rsync nested the directory | Missing trailing slash | `tools/` copies contents |
| Locked out after a firewall push | Rules dropped SSH, no undo | Second session open, undo timer armed first |
| `set -u` on remote `$1` | Remote bash got no arguments | `-- "$port"` goes on the ssh command, before the heredoc |
