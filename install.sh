#!/usr/bin/env bash
# Pi CLI only; no service credential is bundled. Review README before running.
set -euo pipefail
set +x
umask 077
PI_VERSION=1.5.0
NODE_VERSION=22.22.0
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help ]]; then
    printf '%s\n' 'Usage: bash install.sh [--help]' \
      'Interactive Linux installer (Debian/Ubuntu, x64/arm64, glibc).' \
      'Requires bash, python3, curl, tar, xz, sha256sum. No sudo, profiles, ports or PiWeb.' \
      'Reads service key from /dev/tty; saves native auth.json mode 0600.' \
      'Uses PI_CODING_AGENT_DIR or ~/.pi/agent. Close Pi before updating configuration.'
    exit 0
fi
[[ $# == 0 ]] || fail 'Unknown argument; use --help.'
[[ $(uname -s) == Linux && -r /etc/os-release ]] || fail 'Only Debian/Ubuntu Linux is supported.'
# os-release is OS-owned, not downloaded shell code.
. /etc/os-release
case ${ID:-} in debian|ubuntu) ;; *) fail 'Only Debian/Ubuntu is supported; no changes made.' ;; esac
for dep in python3 curl tar xz sha256sum; do
    command -v "$dep" >/dev/null || fail "Missing $dep. Install using your OS package manager, then retry."
done
[[ ${HOME:-} == /* ]] || fail 'HOME must be absolute.'
if ! ( : </dev/tty ) 2>/dev/null; then fail 'An interactive controlling TTY is required (SSH -t); use --help for usage.'; fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
agent=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}
[[ $agent == '~/'* ]] && agent="$HOME/${agent:2}"
[[ $agent == /* ]] || fail 'PI_CODING_AGENT_DIR must be absolute.'
export PI_CODING_AGENT_DIR="$agent"
cat >"$work/config.py" <<'PY'
import getpass, json, os, pathlib, sys, tempfile, time
P = 'modal-heretic'
MODEL = 'heretic9b:q4km'
root = pathlib.Path(os.environ['PI_CODING_AGENT_DIR'])
plan_path = pathlib.Path(sys.argv[2])
names = ('models.json', 'settings.json', 'auth.json')
provider = {
    'baseUrl': 'https://shelliminionhja33--heretic9b-persistent-api-gateway.us-east.modal.run/v1',
    'api': 'openai-completions', 'authHeader': True,
    'models': [{'id': MODEL, 'name': 'Heretic 9B Q4_K_M (Modal L4)',
        'reasoning': False, 'input': ['text'], 'contextWindow': 16384, 'maxTokens': 2048,
        'compat': {'supportsStore': False, 'supportsDeveloperRole': False,
                   'supportsReasoningEffort': False, 'maxTokensField': 'max_tokens'}}]}
def die(msg):
    raise SystemExit('Error: ' + msg)
def pairs(items):
    d = {}
    for k, v in items:
        if k in d: die('Duplicate JSON keys; repair configuration first.')
        d[k] = v
    return d
def snapshot():
    raw, data = {}, {}
    for n in names:
        p = root / n
        if p.is_symlink(): die(n + ' is a symlink; refusing to replace it.')
        try:
            raw[n] = p.read_text(encoding='utf-8') if p.exists() else None
            data[n] = json.loads(raw[n], object_pairs_hook=pairs) if raw[n] is not None else {}
        except (ValueError, OSError, UnicodeError): die('Cannot read valid JSON from ' + n + '; nothing overwritten.')
        if not isinstance(data[n], dict): die(n + ' must contain a JSON object.')
    if not isinstance(data['models.json'].get('providers', {}), dict): die('models.json providers must be an object.')
    return raw, data
def ask(tty, text):
    tty.write(text); tty.flush()
    value = tty_input.readline()
    if not value: die('TTY closed; cancelled.')
    return value.strip().lower()
def atomic(p, text):
    fd, tmp = tempfile.mkstemp(prefix='.' + p.name + '.', dir=p.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
if sys.argv[1] == 'prepare':
    raw, data = snapshot()
    with open('/dev/tty', 'r') as tty_input, open('/dev/tty', 'w', buffering=1) as tty:
        tty.write('Pi Modal setup: native CLI only. Close other Pi processes first.\n'
                  'May download Node 22.22.0 + Pi 1.5.0 into ~/.local/share/pi-modal-setup.\n'
                  'No sudo, shell profiles, SSH, ports or PiWeb changes.\n'
                  'Target agent directory: ' + str(root) + '\n')
        if ask(tty, 'Install/reuse Pi and set Modal as default? [y/N] ') != 'y': die('Cancelled; no changes made.')
        if P in data['models.json'].get('providers', {}):
            if ask(tty, 'Replace existing modal-heretic provider definition (other providers kept)? [y/N] ') != 'y':
                die('Cancelled; no changes made.')
        credential = data['auth.json'].get(P)
        reusable = isinstance(credential, dict) and credential.get('type') == 'api_key' and isinstance(credential.get('key'), str) and bool(credential['key'])
        reuse = reusable and ask(tty, 'Reuse stored modal-heretic API credential? [Y/n] ') in ('', 'y')
        if not reuse:
            key = getpass.getpass('Service API key (hidden; NOT a Modal management token): ', stream=tty)
            # Service keys are opaque URL-safe bearer values. Reject interpolation/commands/placeholders.
            if not key or not all(c.isascii() and (c.isalnum() or c in '_-.') for c in key):
                die('Empty or invalid service key; use the actual service credential, not a reference/placeholder.')
            if key.lower() in ('placeholder', 'your-key', 'service-key') or key.startswith(('ak-', 'as-')):
                die('Placeholder or Modal management token rejected.')
            data['auth.json'][P] = {'type': 'api_key', 'key': key}
    data['models.json'].setdefault('providers', {})[P] = provider
    data['settings.json'].update(defaultProvider=P, defaultModel=MODEL)
    plan_path.write_text(json.dumps({'raw': raw, 'data': data}), encoding='utf-8')
    os.chmod(plan_path, 0o600)
elif sys.argv[1] == 'commit':
    plan = json.loads(plan_path.read_text())
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    locks = []
    try:
        # auth.json.lock matches Pi's proper-lockfile directory convention.
        for n in ('pi-modal-setup.lock', 'auth.json.lock'):
            p = root / n
            try: p.mkdir(mode=0o700)
            except FileExistsError: die('Configuration locked; close Pi/other installer and retry. Never remove a live lock.')
            locks.append(p)
        raw, _ = snapshot()
        if raw != plan['raw']: die('Configuration changed during installation; retry (nothing overwritten).')
        changed = [n for n in names if raw[n] is None or json.loads(raw[n]) != plan['data'][n]
                   or (root / n).stat().st_mode & 0o777 != 0o600]
        if not changed:
            print('Configuration already up to date (no backup needed).')
            sys.exit(0)
        backup = root / ('modal-setup-backup-' + time.strftime('%Y%m%dT%H%M%S') + '-' + str(os.getpid()))
        backup.mkdir(mode=0o700)
        for n in changed:
            if raw[n] is not None: atomic(backup / n, raw[n])
        atomic(backup / 'manifest.json', json.dumps({'changed': changed, 'previouslyAbsent': [n for n in changed if raw[n] is None]}, indent=2) + '\n')
        written = []
        try:
            for n in changed:
                atomic(root / n, json.dumps(plan['data'][n], indent=2, ensure_ascii=False) + '\n')
                written.append(n)
        except BaseException:
            for n in reversed(written):
                if raw[n] is None: (root / n).unlink()
                else: atomic(root / n, raw[n])
            raise
        print('Configuration saved (0600). Backup: ' + str(backup))
    finally:
        for p in reversed(locks): p.rmdir()
else: die('Unknown operation.')
PY
python3 "$work/config.py" prepare "$work/plan.json"
base="$HOME/.local/share/pi-modal-setup"
mkdir -p "$base"
# Keep installs serialized without touching system Node/npm or existing pi.
mkdir "$base/install.lock" 2>/dev/null || fail "Installer locked: $base/install.lock"
trap 'rmdir "$base/install.lock"; rm -rf -- "$work"' EXIT
node_ok() { node -e 'let [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22 || (a===22 && b>=19)?0:1)' >/dev/null 2>&1; }
if ! command -v node >/dev/null || ! node_ok || ! command -v npm >/dev/null; then
    case $(uname -m) in
        x86_64) arch=x64; expected=9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37 ;;
        aarch64|arm64) arch=arm64; expected=1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f ;;
        *) fail 'Node auto-install supports only x64/arm64.' ;;
    esac
    node_dir="$base/node-v$NODE_VERSION-linux-$arch"
    if [[ ! -x $node_dir/bin/node ]]; then
        archive="node-v$NODE_VERSION-linux-$arch.tar.xz"
        printf 'Downloading official Node %s (%s), verifying SHA256...\n' "$NODE_VERSION" "$arch"
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v$NODE_VERSION/$archive" -o "$work/$archive"
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
        grep -Fx "$expected  $archive" "$work/SHASUMS256.txt" >/dev/null || fail 'Official checksum differs from pinned checksum.'
        (cd "$work" && printf '%s  %s\n' "$expected" "$archive" | sha256sum --check --status) || fail 'Node archive checksum mismatch.'
        tar -xJf "$work/$archive" -C "$work"
        [[ ! -e $node_dir ]] || fail "Incomplete Node directory exists: $node_dir; inspect/remove it before retry."
        mv "$work/node-v$NODE_VERSION-linux-$arch" "$node_dir"
    fi
    export PATH="$node_dir/bin:$PATH"
    node_ok || fail 'Downloaded Node cannot run; requires glibc >=2.28. No configuration changed.'
fi
node_bin=$(command -v node)
# Reuse ONLY the tested Pi version. Other installations are never overwritten.
pi_cmd=$(command -v pi || true)
if [[ -n $pi_cmd ]] && [[ $(PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 "$pi_cmd" --version 2>/dev/null) == "$PI_VERSION" ]]; then
    printf 'Reusing Pi %s: %s\n' "$PI_VERSION" "$pi_cmd"
else
    prefix="$base/pi-$PI_VERSION"
    cli="$prefix/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
    if [[ ! -f $cli ]]; then
        stage=$(mktemp -d "$base/.npm-install.XXXXXX")
        # No npmrc/token from the invoking account is needed for this public package.
        : >"$work/user.npmrc"; : >"$work/global.npmrc"
        if ! NPM_CONFIG_USERCONFIG="$work/user.npmrc" NPM_CONFIG_GLOBALCONFIG="$work/global.npmrc" npm install \
            --prefix "$stage" --cache "$base/npm-cache" --ignore-scripts --no-audit --no-fund \
            --registry=https://registry.npmjs.org "@earendil-works/pi-coding-agent@$PI_VERSION"; then
            rm -rf -- "$stage"; fail 'npm install failed; configuration not changed.'
        fi
        [[ ! -e $prefix ]] || { rm -rf -- "$stage"; fail "Incomplete Pi directory: $prefix"; }
        mv "$stage" "$prefix"
    fi
    [[ $(PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 "$node_bin" "$cli" --version) == "$PI_VERSION" ]] || fail 'Pi version verification failed.'
    # The launcher only selects the runtime. Credentials use native auth.json, not shell env.
    launcher="$base/pi"
    printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$node_bin" "$cli" >"$work/launcher"
    chmod 700 "$work/launcher"
    mv "$work/launcher" "$launcher"
    pi_cmd=$launcher
    # Never overwrite an existing pi. Prefer an already-present writable PATH directory.
    if ! command -v pi >/dev/null; then
        IFS=: read -ra path_dirs <<<"$PATH"
        linked=false
        for dir in "${path_dirs[@]}"; do
            [[ $dir == /* && -d $dir && -w $dir && $dir != "$base" ]] || continue
            if [[ ! -e $dir/pi && ! -L $dir/pi ]] && ln -s "$launcher" "$dir/pi" 2>/dev/null; then
                printf 'Pi launcher symlink: %s/pi\n' "$dir"; linked=true; break
            fi
        done
        if [[ $linked == false ]]; then
            printf 'No writable PATH directory. Run %s directly; no profile was modified.\n' "$launcher"
        fi
    else
        printf 'Existing different Pi was not changed. Use %s for tested Pi %s.\n' "$launcher" "$PI_VERSION"
    fi
fi
python3 "$work/config.py" commit "$work/plan.json"
printf '\nReady. Run: %s\n' "$pi_cmd"
printf 'Default: modal-heretic/heretic9b:q4km\nCredential: %s/auth.json (0600)\n' "$agent"
printf '%s\n' 'No API request was sent. Chat will cold-start the GPU and incur charges.'
