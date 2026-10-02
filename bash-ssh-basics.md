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

## While you are learning the material

Script the setup. Type the lesson.

Setup is anything you would redo tomorrow without learning anything new: download a tool, open a port, drop an nginx snippet, copy a binary to the redirector. That goes in a script the second time you do it.

The lesson is the command the page is teaching. Type that one by hand. Scripting it on first contact hides the flag, the path, and the error you were supposed to see.

One file per lab, not one framework. `labs/03-redirector.sh`. Top of the file is variables that change. Body is the commands you already ran.

```bash
#!/bin/bash
set -eu
host=root@10.10.14.4
port=443
upstream=127.0.0.1:8443

ssh "$host" "grep -n listen /etc/nginx/nginx.conf || true"
```

Under that, paste the lesson commands as comments when they work. Promote a comment to a real line only after you have typed it twice.

```bash
# typed twice, now a line:
ssh "$host" "iptables -C INPUT -p tcp --dport ${port} -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport ${port} -j ACCEPT"

# still learning, leave it as a comment:
# ssh "$host" 'nginx -T | grep proxy_pass'
```

Capture without stopping the lab:

- Working command: arrow-up, then `echo 'ssh host ...' >> labs/03-redirector.sh` is too lossy. Instead `history | tail -5` and paste the line into the file before you turn the page.
- A block you just ran: `fc -ln -1` prints the last command. Append it.
- End of the night: `history >> labs/03-history.txt`. In the morning, pull the ten lines you will redo into the `.sh`. Delete the rest.

Variables only for values that change between labs: host, port, interface, upstream. Do not variable the command itself.

A function is earned when the same three lines appear in two lab files. Not before. Copy-paste across two files is fine while the material is new.

Done for the day means: someone else could reset the box and your `.sh` would rebuild the setup, and the lesson commands are still visible as comments you can retype.
