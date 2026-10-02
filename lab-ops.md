# Lab ops playbook

One file. Tomorrow: copy a block, fill in the host, run it. Script setup the second time you do it. Type the lesson by hand.

Do not `iptables -F` over SSH. Do not reload nginx unless `nginx -t` passed.

---

## Tomorrow

```bash
mkdir -p ~/labs
cd ~/labs
# one file per lab. top = values that change. body = commands already typed twice.
```

```bash
#!/bin/bash
set -eu
host=root@10.10.14.4
port=443
upstream=127.0.0.1:8443
```

Capture before you turn the page: `history | tail -5`, paste the line. End of night: `history >> ~/labs/today-history.txt`. Morning: move the ten lines you will redo into the `.sh`.

Single quotes send text unchanged (`'echo $HOME'` is the remote home). Double quotes expand on your laptop first. If unsure, put the lines in a file and send the file.

---

## Operators

| See | Means |
| --- | --- |
| `set -eu` | Stop on first failure. Die on an unset variable. Put this at the top of every script you send. |
| `"$var"` | Use the value. Always quote. |
| `${port:-443}` | Value, or 443 if empty. |
| `${1:?need host}` | Required. Exit with that message if missing. |
| `cmd && next` | Run next only if cmd worked. |
| `cmd \|\| next` | Run next only if cmd failed. |
| `$(cmd)` | Use the command's output as text. |
| `<<'EOF'` | Send the following lines as stdin. Quotes on the tag: your laptop does not expand `$`. Line that is only `EOF` ends it. |
| `"$@"` | All arguments, each kept separate. |

---

## Send a command

```bash
ssh user@host hostname
ssh user@host 'grep server_name /etc/nginx/nginx.conf'
ssh user@host 'bash -s' < job.sh
ssh user@host 'sudo bash -s' < job.sh
```

Several lines, no file:

```bash
ssh root@host 'bash -s' <<'EOF'
set -eu
cp -a /etc/nginx/nginx.conf /root/nginx.conf.bak
echo backup made
EOF
```

Passwordless sudo, or the script hangs. `ssh root@host` avoids that. Reuse the connection: in `~/.ssh/config`

```text
Host redir
    HostName 10.10.14.4
    User root
    IdentityFile ~/.ssh/lab_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Then `ssh redir 'id'`. Close it with `ssh -O exit redir`.

---

## nginx

Do not edit the live file from a script. Write a snippet. Second run overwrites it.

`nginx-site.sh`:

```bash
#!/bin/bash
set -eu
install -d /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/lab.conf <<'SITE'
server {
    listen 8080;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:8443;
        proxy_set_header Host $host;
    }
}
SITE
ln -sfn /etc/nginx/sites-available/lab.conf /etc/nginx/sites-enabled/lab.conf
nginx -t
systemctl reload nginx
```

```bash
ssh root@host 'bash -s' < nginx-site.sh
```

`$host` in the snippet is nginx's. The quotes on `<<'SITE'` keep your laptop from eating it. `nginx -t` before reload: a bad file does not take the site down. Change the port in the file and send it again.

One line in the main file, only after you have seen it with grep:

```bash
ssh root@host 'bash -s' <<'EOF'
set -eu
cp -a /etc/nginx/nginx.conf /root/nginx.conf.bak
sed -i 's/worker_connections 768;/worker_connections 2048;/' /etc/nginx/nginx.conf
nginx -t
systemctl reload nginx
EOF
```

If the test fails: `cp /root/nginx.conf.bak /etc/nginx/nginx.conf`.

---

## iptables

`-A` appends. Twice means the rule is there twice. Check, then add.

`fw-add.sh`:

```bash
#!/bin/bash
set -eu
add() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }
add INPUT -p tcp --dport 22 -j ACCEPT
add INPUT -p tcp --dport 443 -j ACCEPT
iptables -S
```

```bash
ssh root@host 'bash -s' < fw-add.sh
```

`iptables -C` fails if the rule is missing. `||` adds it only then.

Save after the live rules look right:

```bash
ssh root@host 'iptables-save > /root/fw.rules'
# later, on that box:
# iptables-restore < /root/fw.rules
```

Forward a port. This replaces the nat and filter tables in the file. Keep the SSH allow.

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

Open a second SSH session first. Arm an undo, load, prove SSH works, disarm.

```bash
ssh root@host 'iptables-save > /root/fw-known-good.rules'
ssh root@host 'nohup bash -c "sleep 120; iptables-restore < /root/fw-known-good.rules" >/tmp/fw-undo.log 2>&1 & echo $! > /tmp/fw-undo.pid'
ssh root@host 'iptables-restore' < fw-redirector.rules
ssh root@host 'true' && ssh root@host 'kill $(cat /tmp/fw-undo.pid) 2>/dev/null || true'
```

Forwarding also needs `sysctl -w net.ipv4.ip_forward=1`.

---

## Download, then copy

`tools.txt`, one tool per line. Pin the version in the URL.

```text
# name  url
ligolo  https://example.test/ligolo.tar.gz
chisel  https://example.test/chisel.gz
```

```bash
#!/bin/bash
set -eu
dest="${1:-$HOME/tools}"
mkdir -p "$dest"
while read -r name url _; do
  [ -z "${name:-}" ] && continue
  case "$name" in \#*) continue ;; esac
  mkdir -p "$dest/$name"
  out="$dest/$name/$(basename "$url")"
  [ -f "$out" ] && echo "have $name" && continue
  curl -fsSL --retry 3 -o "$out.partial" "$url"
  mv "$out.partial" "$out"
done < tools.txt
```

Copy. Trailing slash copies contents, not the directory itself.

```bash
rsync -a "$HOME/tools/" root@host:/opt/tools/
rsync -a "$HOME/tools/ligolo" root@host:/opt/tools/
```

---

## Docker

From Kali, against the remote daemon. Unset when done or the next local `docker ps` hits the lab box.

```bash
export DOCKER_HOST=ssh://root@host
docker compose -f compose/lab.yml up -d
unset DOCKER_HOST
```

On the box, idempotent. `docker run` twice errors on the name.

```bash
ssh root@host 'bash -s' <<'EOF'
set -eu
name=lab-nginx
if ! docker inspect "$name" >/dev/null 2>&1; then
  docker run -d --name "$name" --restart unless-stopped -p 8080:80 nginx:1.27
else
  docker start "$name" >/dev/null
fi
EOF
```

Pin the tag. Do not use `latest`.

---

## Tiny SHell client

Same shape as ssh. Secret from the environment, not the file.

```bash
export TSH_SECRET='set-this-in-the-shell'
tsh root@host 'uname -a'
tsh root@host get /remote/file ./
tsh root@host put ./local /remote/
```

---

## Long-running binary on your box

A listener or proxy is a unit, not `nohup`.

```bash
ssh root@host 'bash -s' <<'EOF'
set -eu
cat > /etc/systemd/system/lab-listener.service <<'UNIT'
[Service]
ExecStart=/opt/tools/listener
Restart=on-failure
WorkingDirectory=/opt/tools
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now lab-listener
systemctl --no-pager --full status lab-listener
EOF
```

Do not commit secrets. Keep them in the shell or a `600` file on the box.

---

## When it breaks

| What you see | Fix |
| --- | --- |
| Hangs, no output | sudo wants a password, or ssh wants a host key. Use root, or accept the key once by hand. |
| Remote `$host` empty | Heredoc was unquoted. Use `<<'EOF'`. |
| iptables rule doubled | You used `-A` twice. Use the `iptables -C \|\| iptables -A` block. |
| Locked out after firewall | No second session, no undo. Arm the 120s restore before the load. |
| Second `docker run` fails | Name exists. `docker start` that name, or compose. |
| rsync made `/opt/tools/tools/` | Missing trailing slash. Use `tools/`. |
| nginx down after edit | `nginx -t` was skipped. Copy the `.bak` back. |
