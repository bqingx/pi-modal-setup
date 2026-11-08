#!/usr/bin/env python3
"""Opt-in network test: real Node/Pi download in temporary HOME; NO inference/API calls."""
import json
import os
import pathlib
import subprocess
import tempfile
from test_installer import tty_run, DUMMY

with tempfile.TemporaryDirectory(prefix='pi-modal-live-') as tmp:
    home = pathlib.Path(tmp)
    bindir = home / 'bin'; bindir.mkdir()
    # Simulate an unusable/old Node. Installer must obtain its own verified runtime.
    node = bindir / 'node'; node.write_text('#!/bin/bash\nexit 1\n'); node.chmod(0o700)
    env = {'HOME': tmp, 'PATH': str(bindir) + ':/usr/bin:/bin',
           'PI_CODING_AGENT_DIR': str(home / 'agent'), 'TERM': 'xterm', 'LANG': 'C.UTF-8',
           'PI_OFFLINE': '1', 'PI_SKIP_VERSION_CHECK': '1', 'PI_TELEMETRY': '0'}
    status, out = tty_run(env, [('[y/N]', 'y'), ('Service API key', DUMMY)], timeout=300)
    assert status == 0, out
    assert DUMMY not in out
    launcher = home / '.local/share/pi-modal-setup/pi'
    assert launcher.exists(), out
    r = subprocess.run([str(launcher), '--offline', '--no-extensions', '--no-mcp',
                        '--no-skills', '--no-context-files', '--no-prompt-templates',
                        '--no-themes', '--no-tools', '--no-approve', '--list-models', 'heretic'],
                       cwd=home, env=env, text=True, capture_output=True, timeout=60)
    assert r.returncode == 0, r.stderr
    assert 'heretic9b:q4km' in r.stdout, r.stdout
    print(r.stdout.strip())
    core = home / '.local/share/pi-modal-setup/pi-1.5.0/node_modules/@earendil-works/pi-coding-agent/dist/core'
    probe = home / 'probe.mjs'
    probe.write_text('''import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { ModelRuntime } from '%s/model-runtime.js';
import { findInitialModel } from '%s/model-resolver.js';
const runtime = await ModelRuntime.create({allowModelNetwork:false});
const s = JSON.parse(readFileSync(process.env.PI_CODING_AGENT_DIR+'/settings.json','utf8'));
const result = await findInitialModel({scopedModels:[],isContinuing:false,
 defaultProvider:s.defaultProvider,defaultModelId:s.defaultModel,modelRuntime:runtime});
assert.equal(result.model.provider,'modal-heretic');
assert.equal(result.model.id,'heretic9b:q4km');
const resolved = await runtime.getAuth('modal-heretic');
assert.ok(resolved);
// Inspect readiness without printing any credential or making a network request.
console.log('PASS: native auth.json resolution and saved default selection (offline).');
''' % (core.as_uri(), core.as_uri()))
    real_node = next((home / '.local/share/pi-modal-setup').glob('node-*/bin/node'))
    r = subprocess.run([str(real_node), str(probe)], cwd=home, env=env, capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    print(r.stdout.strip())
    for name in ('models.json', 'settings.json', 'auth.json'):
        p = home / 'agent' / name
        assert p.stat().st_mode & 0o777 == 0o600
        if name != 'auth.json': assert DUMMY not in p.read_text()
    print('PASS: official pinned Node SHA256 + real npm --ignore-scripts + Pi 1.5.0 + 0600; no model call.')
