# Bash ops reference

Small set of bash you can reuse for a course lab: download a list of tools, load iptables, drop a file on a remote host, render an nginx config. No giant `case` block.

You do not need much bash. You need the same twelve ideas, used the same way every time. Each section is a thing you can copy, then a "what that line means" note.

Run any example twice. If the second run errors or duplicates a rule, it is not done.

---

## 1. The only header

Put this at the top of every script you execute. Do not put it in a file you `source`.

```bash
#!/usr/bin/env bash
set -euo pipefail
```

| Piece | Meaning |
| --- | --- |
| `#!/usr/bin/env bash` | Run this file with bash, not sh. `env` finds bash on `$PATH`. |
| `set -e` | Stop the script if a command fails. Default bash keeps going. |
| `set -u` | Typo in a variable name is an error. `$DEST` when you meant `$dest` dies here instead of expanding to empty. |
| `set -o pipefail` | A pipeline fails if any part fails, not just the last command. `curl ... \| tar` will not succeed when curl failed. |

`-E` (traps inherited by functions) is optional. Skip it until you use `trap`.

---

## 2. A function is a named block

A function is a label on some lines. That is the whole idea. You call it by name.

```bash
log() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

need() {
  command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }
}

log "starting"
need curl
```

| Piece | Meaning |
| --- | --- |
| `log()` | Define a function named `log`. The `()` is required. No `function` keyword needed. |
| `"$*"` | All arguments joined by a space. `log hello there` prints `hello there`. |
| `"$1"` | First argument only. |
| `>/dev/null` | Throw away stdout. `2>/dev/null` would throw away stderr. |
| `\|\| { ...; }` | Run the block only if the command on the left failed. |
| `>&2` | Print to stderr, not stdout. Errors go here. |

Variables inside a function are global unless you mark them `local`. Always `local` ones that should not leak.

```bash
greet() {
  local name="$1"
  echo "hi $name"
}
```

---

## 3. `source` is how you split files

`source ./lib/common.sh` runs that file in the current shell, so its functions exist afterward. It is not a subprocess. That is why a giant script becomes three short files.

```text
ops/
  bin/ops            # the script you run
  lib/common.sh      # log, need
  conf/tools.txt     # data, not code
```

```bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
```

| Piece | Meaning |
| --- | --- |
| `BASH_SOURCE[0]` | Path of the file currently running, even if you called it from another directory. |
| `dirname` | Strip the filename, leave the directory. |
| `cd ... && pwd` | Turn that into an absolute path. The `&&` means `pwd` runs only if `cd` worked. |
| `"$(...)"` | Command substitution. The output of the command becomes the value. Quotes so spaces in the path do not split it. |

Call scripts by path after this, not by assuming you are in the repo root.

---

## 4. The dispatcher, which replaces the case block

Name every job `cmd_<something>`. The first argument is the job name. One `if` calls it. Adding a job is adding a function, not a new branch.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

cmd_pull() { log "pull $*"; }
cmd_fw()   { log "fw $*"; }
cmd_help() { echo "usage: ops pull|fw"; }

cmd="${1:-help}"
shift || true
if declare -F "cmd_$cmd" >/dev/null; then
  "cmd_$cmd" "$@"
else
  echo "unknown: $cmd" >&2
  cmd_help
  exit 1
fi
```

```text
ops pull
ops fw redirector
```

| Piece | Meaning |
| --- | --- |
| `${1:-help}` | First argument, or `help` if there is no first argument. The `:-` is the default. |
| `shift` | Drop the first argument. Everything that was `$2` is now `$1`. |
| `shift \|\| true` | `shift` fails if there was nothing to drop. `\|\| true` keeps `set -e` from killing the script. |
| `declare -F name` | Succeeds if a function with that name exists. This is the check. It is not advanced; it is "does this function exist?". |
| `"cmd_$cmd" "$@"` | Call the function. The quotes on `"$@"` keep each remaining argument separate. |

You do not need `getopts` for this. Positional args are enough: job, host, dest. Flags (`-v`, `-f file`) are the only time `getopts` earns its place. See the glossary.

---

## 5. Arguments, the three forms you will use

```bash
host="${1:?need user@host}"   # die with that message if missing
dest="${2:-/opt/tools}"        # default if missing
name="$3"                      # may be empty; you check it yourself
```

| Form | Meaning |
| --- | --- |
| `${1:?msg}` | Required. Exit if unset or empty, print `msg`. |
| `${2:-default}` | Optional. Use `default` if unset or empty. |
| `$3` | Plain. Empty is allowed. |

Quote every expansion you pass to a command: `"$host"`, not `$host`.

---

## 6. Downloads from a list, not a case per tool

Data goes in a file. The script is a loop. A new tool is a new line.

`conf/tools.txt`:

```text
# name  url
ligolo  https://example.test/ligolo.tar.gz
chisel  https://example.test/chisel.gz
```

```bash
cmd_pull() {
  local dest="${1:-$HOME/tools}"
  local name url
  install -d "$dest"
  while read -r name url _; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    if [[ -f "$dest/$name/$(basename "$url")" ]]; then
      log "have $name"
      continue
    fi
    install -d "$dest/$name"
    log "get $name"
    curl -fsSL --retry 3 -o "$dest/$name/$(basename "$url").partial" "$url"
    mv "$dest/$name/$(basename "$url").partial" "$dest/$name/$(basename "$url")"
  done < "$ROOT/conf/tools.txt"
}
```

| Piece | Meaning |
| --- | --- |
| `while read -r name url _` | Read one line. First word to `name`, second to `url`, rest thrown away in `_`. `-r` means do not treat backslash specially. |
| `done < file` | Feed the file to the loop as stdin. |
| `[[ -z ... ]]` | True if the string is empty. `[[ ]]` is the bash test. Prefer it over `[ ]`. |
| `\|\|` inside `[[ ]]` | Or. `&&` is and. |
| `\#*` | A word that starts with `#`. The backslash is so the file itself is not treated as a comment by a sloppy editor; in `[[ ]]` `"$name" == \#*` is a pattern match. |
| `&& continue` | If the test passed, skip to the next line. |
| `install -d` | `mkdir -p` that also sets mode. Fine to use `mkdir -p` instead. |
| `curl -f` | Fail on HTTP 404. Without `-f`, curl exits 0 and you save an error page. |
| `-sSL` | Silent, show errors, follow redirects. |
| `.partial` then `mv` | A killed download does not leave a file the next run trusts. `mv` on the same filesystem is atomic. |

Pin the version in the URL. `latest` will break a lab on the day upstream moves a flag.

---

## 7. iptables: write a rules file, load it

Do not script a chain of `iptables -A`. The second run duplicates rules. Build the rules once by hand, save them, and reload the file.

```bash
# after the rules work by hand:
iptables-save > conf/fw-redirector.rules

# in the script:
cmd_fw() {
  local role="${1:?need a role, e.g. redirector}"
  local conf="$ROOT/conf/fw-$role.rules"
  [[ -f "$conf" ]] || { echo "no rules: $conf" >&2; exit 1; }
  iptables-restore < "$conf"
  log "loaded $role"
}
```

`iptables-restore` replaces the table it is loading. You do not also `iptables -F`.

Do not flush `INPUT` on a remote host from a script unless a second SSH session is already open. A bad rules file locks you out. On a remote box, keep a fallback:

```bash
# in another terminal, before you load rules:
sleep 120 && iptables-restore < /root/fw-known-good.rules
```

Cancel that if the new rules worked and you can still SSH.

A rules file looks like the output of `iptables-save`. You can hand-write one:

```text
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp --dport 22 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
COMMIT
```

Different host, different file (`fw-student.rules`, `fw-redirector.rules`). Do not branch on hostname inside the script.

---

## 8. nginx: a template plus a variable file

Config with holes in it lives in a template. Values live in an env file. `envsubst` fills the holes. That is the whole trick.

`conf/redirector.env`:

```bash
LISTEN=443
UPSTREAM=10.10.14.20:8443
SERVER_NAME=cdn.example.test
CERT=/etc/nginx/certs/fullchain.pem
KEY=/etc/nginx/certs/privkey.pem
```

`templates/redirector.conf.tmpl`:

```nginx
server {
    listen ${LISTEN} ssl;
    server_name ${SERVER_NAME};
    ssl_certificate     ${CERT};
    ssl_certificate_key ${KEY};
    location / {
        proxy_pass https://${UPSTREAM};
        proxy_ssl_verify off;
        proxy_set_header Host $host;
    }
}
```

```bash
cmd_redirector() {
  local host="${1:?need user@host}"
  set -a
  source "$ROOT/conf/redirector.env"
  set +a
  local rendered
  rendered="$(mktemp)"
  envsubst '${LISTEN} ${UPSTREAM} ${SERVER_NAME} ${CERT} ${KEY}' \
    < "$ROOT/templates/redirector.conf.tmpl" > "$rendered"
  scp -q "$rendered" "$host:/tmp/redirector.conf"
  rm -f "$rendered"
  ssh -o BatchMode=yes "$host" 'bash -seuo pipefail' <<'REMOTE'
install -D -m 644 /tmp/redirector.conf /etc/nginx/sites-available/redirector.conf
ln -sfn /etc/nginx/sites-available/redirector.conf /etc/nginx/sites-enabled/redirector.conf
nginx -t
systemctl reload nginx
REMOTE
  log "reloaded on $host"
}
```

| Piece | Meaning |
| --- | --- |
| `set -a` / `source` / `set +a` | `-a` auto-exports every variable that gets set. `source` then loads the env file into the environment, which is what `envsubst` reads. `+a` turns auto-export back off. |
| `mktemp` | Empty temp file with a random name. |
| `envsubst 'list'` | Replace only those `${VARS}`. The single quotes are required. |
| Why the quotes matter | Without them, envsubst also replaces `$host` inside the nginx config. Nginx needs that `$host` left alone. This is the bug that looks like a working script and a broken proxy. |
| `<<'REMOTE'` | Heredoc. Everything until a line that is only `REMOTE` is the stdin of `ssh`. The quotes on `'REMOTE'` mean your local shell does not expand `$` inside it. |
| `nginx -t` | Test config. With `set -e`, a bad config skips the reload, so nginx keeps the old file. |
| `ln -sfn` | Replace a symlink if it already exists. Second run works. |
| `BatchMode=yes` | Fail instead of asking for a password. You want a key here. |

`envsubst` is in the `gettext-base` package. Already on Kali.

Certs are files, not template values. `scp` them once, mode `600`, and only put the path in the env file.

---

## 9. Copy tools to a host

The directory name is the tool name, because `cmd_pull` already built it that way. No per-tool branch.

```bash
cmd_throw() {
  local host="${1:?need user@host}"
  local dest="${2:-/opt/tools}"
  shift 2
  if (( $# )); then
    local n
    for n in "$@"; do
      rsync -a "$HOME/tools/$n" "$host:$dest/"
    done
  else
    rsync -a "$HOME/tools/" "$host:$dest/"
  fi
}
```

```text
ops throw user@box /opt/tools ligolo chisel
ops throw user@box /opt/tools
```

| Piece | Meaning |
| --- | --- |
| `shift 2` | Drop the first two args (host and dest). What remains is the list of tool names. |
| `(( $# ))` | Arithmetic test. True if the number of remaining args is not zero. |
| `for n in "$@"` | Loop over remaining args. Quoted `"$@"` so names with spaces survive. They should not have spaces anyway. |
| `rsync -a` | Copy, keep times and permissions, skip files that are already the same. |

---

## 10. Glossary, the lines that look advanced

| You see | It means |
| --- | --- |
| `"$var"` | Use the value. Always quote. |
| `"${var}"` | Same thing. Braces matter when the next character would stick to the name: `"${var}_backup"`. |
| `${var:-fallback}` | Value, or fallback if empty. |
| `${var:?message}` | Value, or exit if empty. |
| `$(cmd)` | Run cmd, use its output as text. |
| `$((1 + 2))` | Arithmetic. |
| `[[ a == b ]]` | Test. Use this, not `[ ]`, in bash. |
| `[[ -f path ]]` | File exists. `-d` directory, `-z` empty string, `-n` non-empty. |
| `cmd && other` | Run `other` only if `cmd` succeeded. |
| `cmd \|\| other` | Run `other` only if `cmd` failed. |
| `local x="$1"` | Variable that dies when the function returns. |
| `source file` | Run file here. Functions and variables stick. |
| `declare -F name` | Does function `name` exist? |
| `"$@"` | All arguments, each kept separate. |
| `$#` | How many arguments. |
| `shift` | Drop `$1`. |
| `<<'EOF'` | Feed the following lines as stdin. Quotes on the tag mean no local `$` expansion. |
| `$(mktemp)` | Temp filename. |
| `install -D -m 644 src dest` | Copy to dest, create parent dirs, set mode. |
| `ln -sfn target link` | Symlink, replace if it exists. |
| `command -v curl` | Path of curl, or failure if it is not installed. |
| `getopts "vhf:" opt` | Only when you want flags. `f:` means `-f` takes an argument, available as `$OPTARG`. After the loop, `shift $((OPTIND - 1))` leaves the non-flag args. Skip this until a script actually has flags. |

`getopts` skeleton, for the day you need it:

```bash
verbose=0
file=""
while getopts ":vf:" opt; do
  case "$opt" in
    v) verbose=1 ;;
    f) file="$OPTARG" ;;
    :) echo "missing value for -$OPTARG" >&2; exit 1 ;;
    ?) echo "unknown -$OPTARG" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
```

The leading `:` in `":vf:"` means you handle errors yourself. This small case is fine. It is parsing flags, not dispatching jobs. Job dispatch stays the function-name trick in section 4.

---

## 11. Rules that keep the case block from growing back

- New behavior is a new function, or a new line in a file under `conf/`. An `if` on a hostname is a smell.
- Arguments stay few: job, host, dest. Anything else is a file.
- The script is a recording of commands you already ran by hand. Write it after, not before.
- Fail loud. `curl -f`, `nginx -t`, `ssh -o BatchMode=yes`.
- Second run must work. That is the test.
- Do not parallelize, background, or add `getopts` until the sequential script is boring.

Speed of the script does not matter. Curl, ssh, and nginx dominate.

When a job grows real conditionals across many different hosts, stop stretching bash. A short Ansible play is the next step, not a bigger case statement.
