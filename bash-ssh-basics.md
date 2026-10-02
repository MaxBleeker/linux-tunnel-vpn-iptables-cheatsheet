# Bash and SSH, the basic method

Do the thing by hand. Paste the working lines into a file. Send that file over SSH. Stop there.

Do not write a dispatcher, a template engine, or a case block until you have done this for three different jobs and the copy-paste is annoying you.

---

## The method

1. SSH in and run the command until it works. History has the exact line.
2. Paste those lines into `job.sh` on your Kali box.
3. From Kali, run `ssh user@host 'bash -s' < job.sh`
4. Run it a second time. If the second run breaks the box, add a check (backup, or "add only if missing").
5. Done. Next job is a new file, not a new branch in this file.

A script is a recording. If you cannot do the task by hand, you cannot script it yet.

---

## Three ways to send a command

One command, no spaces that matter:

```bash
ssh user@host hostname
```

One command with spaces or pipes. Single quotes so your laptop does not touch it:

```bash
ssh user@host 'grep server_name /etc/nginx/nginx.conf'
```

Several lines. Write them locally, send them on stdin:

```bash
ssh user@host 'bash -s' <<'EOF'
set -eu
cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
echo "backup made"
EOF
```

`<<'EOF'` means "send these lines as the script." The quotes on `'EOF'` mean your laptop does not expand `$`. The other side does. End the block with a line that is only `EOF`.

`set -eu` means stop on the first failed command, and die if you use a variable that was never set. Put it at the top of every script you send.

Root on the far side, when you already have passwordless sudo:

```bash
ssh user@host 'sudo bash -s' <<'EOF'
set -eu
iptables -S
EOF
```

If sudo asks for a password, the script hangs. Fix sudo once by hand, or use `ssh root@host`.

---

## Edit nginx.conf

Do not hand-edit the live file from a script. Drop a snippet in `sites-enabled` and reload. Second run overwrites the same snippet, so it is safe.

`nginx-site.sh` on your Kali box:

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

Send it:

```bash
ssh root@host 'bash -s' < nginx-site.sh
```

What matters:

- `cat > file <<'SITE'` writes the block to that file. It replaces the file. Running it again is fine.
- `ln -sfn` replaces the symlink if it is already there.
- `nginx -t` checks the config. `set -e` skips the reload if the test fails, so a bad edit does not take down the old site.
- `$host` inside the snippet is for nginx. The quotes on `<<'SITE'` keep your laptop from eating it.

Change the port or the upstream by editing `nginx-site.sh` and sending it again. You do not SSH in and open vim.

To change one line in the main file instead of a snippet, backup first, then replace:

```bash
ssh root@host 'bash -s' <<'EOF'
set -eu
cp -a /etc/nginx/nginx.conf /root/nginx.conf.bak
sed -i 's/worker_connections 768;/worker_connections 2048;/' /etc/nginx/nginx.conf
nginx -t
systemctl reload nginx
EOF
```

`sed -i` edits in place. Only do this for a line you have already seen with `grep`. If `nginx -t` fails, copy the backup back: `cp /root/nginx.conf.bak /etc/nginx/nginx.conf`.

---

## Add an iptables rule

`iptables -A` appends. Run it twice and you have the rule twice. Check, then add.

`fw-add.sh`:

```bash
#!/bin/bash
set -eu
add() {
  iptables -C "$@" 2>/dev/null || iptables -A "$@"
}
add INPUT -p tcp --dport 22 -j ACCEPT
add INPUT -p tcp --dport 443 -j ACCEPT
iptables -S
```

Send it:

```bash
ssh root@host 'bash -s' < fw-add.sh
```

`iptables -C` asks "is this rule already there?" It fails if not. `||` means "if that failed, add it." Second run adds nothing.

Save so a reboot keeps the rules, after the live rules look right:

```bash
ssh root@host 'iptables-save > /etc/iptables/rules.v4'
```

Debian/Kali needs the `iptables-persistent` package for that path. If the directory is missing, save to `/root/fw.rules` and load next time with `iptables-restore < /root/fw.rules`.

Do not `iptables -F` over SSH. That drops the SSH rule and locks you out. Add rules. Do not flush.

---

## Quoting, the only rule you need

Single quotes mean "send this text unchanged."

```bash
ssh user@host 'echo $HOME'     # prints the remote home
```

Double quotes mean "your laptop expands it, then sends the result."

```bash
name=lab
ssh user@host "grep $name /etc/nginx/sites-enabled/lab.conf"
```

If you are not sure, use single quotes and a script file. Files do not have this problem: `ssh host 'bash -s' < job.sh` sends the file as-is.

---

## While you are learning the material

Script the setup. Type the lesson.

Setup is anything you would redo tomorrow without learning anything new: download a tool, open a port, drop an nginx snippet, copy a binary to the redirector. That goes in a script the second time you do it.

The lesson is the command the page is teaching. Type that one by hand. Scripting it on first contact hides the flag, the path, and the error you were supposed to see.

One file per lab, not one framework. `labs/03-redirector.sh`. Top of the file is values that change. Body is commands you already ran.

```bash
#!/bin/bash
set -eu
host=root@10.10.14.4
port=443
upstream=127.0.0.1:8443
```

Under that, paste a working command as a comment. Promote the comment to a real line only after you have typed it twice.

```bash
# typed twice, now a line:
ssh "$host" "iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${port} -j ACCEPT"

# still learning, leave it as a comment:
# ssh "$host" 'nginx -T | grep proxy_pass'
```

Capture without stopping the lab. Before you turn the page, `history | tail -5` and paste the line you will redo. End of the night, `history >> labs/03-history.txt`. In the morning, pull the ten lines you will redo into the `.sh` and delete the rest.

Variables only for values that change between labs: host, port, interface, upstream. Do not variable the command itself.

A function is earned when the same three lines show up in two lab files. Not before. Copy-paste across two files is fine while the material is new.

Done for the day means someone else could reset the box and your `.sh` would rebuild the setup, and the lesson commands are still sitting there as comments you can retype.

---

## When a script is done

- It runs twice without error.
- A failed `nginx -t` does not reload.
- An iptables rule is not duplicated.
- You can read it a week later and see the commands you would have typed.
