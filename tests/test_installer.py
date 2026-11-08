#!/usr/bin/env python3
"""Offline installer tests. All credentials are synthetic, HOME/agent/PATH isolated."""
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'install.sh'
DUMMY = 'dummy-non-secret-test-key'

def tty_run(env, answers, timeout=60):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(env['HOME'])
        os.execve('/bin/bash', ['bash', str(SCRIPT)], env)
    output = b''
    deadline = time.monotonic() + timeout
    pending = list(answers)
    try:
        while time.monotonic() < deadline:
            if select.select([fd], [], [], .1)[0]:
                try: chunk = os.read(fd, 65536)
                except OSError: break
                if not chunk: break
                output += chunk
                if pending and pending[0][0].encode() in output:
                    _, answer = pending.pop(0)
                    os.write(fd, answer.encode() + b'\n')
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                return os.waitstatus_to_exitcode(status), output.decode(errors='replace')
        else:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            raise AssertionError('TTY timeout: ' + output.decode(errors='replace'))
        _, status = os.waitpid(pid, 0)
        return os.waitstatus_to_exitcode(status), output.decode(errors='replace')
    finally:
        os.close(fd)

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pi-modal-test-')
        self.home = pathlib.Path(self.tmp.name)
        self.bin = self.home / 'bin'; self.bin.mkdir()
        # Only disposable PATH entries are writable, even when tests run as root.
        for name in ('python3', 'curl', 'tar', 'xz', 'sha256sum', 'uname', 'mktemp', 'rm',
                     'mkdir', 'rmdir', 'cat', 'mv', 'chmod', 'grep', 'ln', 'bash'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.executable('node', '#!/bin/bash\nexit 0\n')
        self.executable('pi', '#!/bin/bash\nprintf "1.5.0\\n"\n')
        self.executable('npm', '#!/bin/bash\nprintf "npm unexpectedly invoked" >&2; exit 99\n')
        self.agent = self.home / 'custom-agent'
        self.env = {'HOME': str(self.home), 'PATH': str(self.bin),
                    'PI_CODING_AGENT_DIR': str(self.agent), 'TERM': 'xterm', 'LANG': 'C.UTF-8'}

    def tearDown(self): self.tmp.cleanup()
    def executable(self, name, text):
        p = self.bin / name
        if p.is_symlink(): p.unlink()
        p.write_text(text); p.chmod(0o700)
    def run_install(self, answers=None):
        return tty_run(self.env, answers if answers is not None else [('[y/N]', 'y'), ('Service API key', DUMMY)])
    def load(self, name): return json.loads((self.agent / name).read_text())
    def seed(self, name, value):
        self.agent.mkdir(exist_ok=True)
        (self.agent / name).write_text(json.dumps(value))
    def test_fresh_repeat_merge_permissions(self):
        self.seed('models.json', {'providers': {'other': {'baseUrl': 'http://localhost/v1'}}})
        oauth = {'type': 'oauth', 'access': 'dummy', 'refresh': 'dummy', 'expires': 9999999999999}
        self.seed('auth.json', {'other': oauth})
        self.seed('settings.json', {'theme': 'dark', 'compaction': {'enabled': False}})
        status, out = self.run_install()
        self.assertEqual(status, 0, out)
        self.assertNotIn(DUMMY, out)
        self.assertEqual(self.load('auth.json')['other'], oauth)
        self.assertIn('other', self.load('models.json')['providers'])
        self.assertEqual(self.load('settings.json')['theme'], 'dark')
        self.assertEqual(self.load('settings.json')['defaultModel'], 'heretic9b:q4km')
        for name in ('models.json', 'settings.json', 'auth.json'):
            self.assertEqual((self.agent / name).stat().st_mode & 0o777, 0o600)
        for name in ('models.json', 'settings.json'):
            self.assertNotIn(DUMMY, (self.agent / name).read_text())
            self.assertNotIn('apiKey', (self.agent / name).read_text())
        backups = list(self.agent.glob('modal-setup-backup-*'))
        self.assertEqual(len(backups), 1)
        for p in backups[0].iterdir(): self.assertEqual(p.stat().st_mode & 0o777, 0o600)
        before = {n: (self.agent / n).read_bytes() for n in ('models.json', 'auth.json', 'settings.json')}
        status, out = self.run_install([('[y/N]', 'y'), ('Replace existing', 'y'), ('Reuse stored', '')])
        self.assertEqual(status, 0, out)
        self.assertEqual(before, {n: (self.agent / n).read_bytes() for n in before})
        self.assertEqual(len(list(self.agent.glob('modal-setup-backup-*'))), 1)
    def test_invalid_json_rejected_all_files(self):
        for name in ('models.json', 'settings.json', 'auth.json'):
            with self.subTest(name=name):
                self.agent.mkdir(exist_ok=True)
                p = self.agent / name; p.write_text('{broken')
                status, out = self.run_install([])
                self.assertNotEqual(status, 0, out)
                self.assertEqual(p.read_text(), '{broken')
                self.assertFalse(list(self.agent.glob('modal-setup-backup-*')))
                p.unlink()
    def test_cancel_and_empty_key(self):
        for answers in ([('[y/N]', 'n')], [('[y/N]', 'y'), ('Service API key', '')]):
            status, out = self.run_install(answers)
            self.assertNotEqual(status, 0, out)
            self.assertFalse(self.agent.exists())
            self.assertFalse((self.home / '.local').exists())
    def test_target_update_cancel(self):
        self.seed('models.json', {'providers': {'modal-heretic': {'models': []}}})
        before = (self.agent / 'models.json').read_bytes()
        status, out = self.run_install([('[y/N]', 'y'), ('Replace existing', 'n')])
        self.assertNotEqual(status, 0, out)
        self.assertEqual(before, (self.agent / 'models.json').read_bytes())
    def test_non_tty_and_help(self):
        for args, expected in (([], 1), (['--help'], 0)):
            r = subprocess.run(['/bin/bash', str(SCRIPT)] + args, env=self.env,
                               stdin=subprocess.DEVNULL, capture_output=True, start_new_session=True)
            self.assertEqual(r.returncode, expected, r.stderr)
        self.assertFalse(self.agent.exists())
    def test_stdin_pipe_uses_tty(self):
        # Feed the installer itself down a pipe; all answers must still use /dev/tty.
        global SCRIPT
        original = SCRIPT
        wrapper = self.home / 'run-pipe.sh'
        wrapper.write_text('#!/bin/bash\n' + str(self.bin / 'cat') + ' ' + str(original) + ' | /bin/bash\n')
        try:
            SCRIPT = wrapper
            status, out = self.run_install()
            self.assertEqual(status, 0, out)
            self.assertNotIn(DUMMY, out)
        finally: SCRIPT = original
    def test_missing_node_checksum_failure_no_config(self):
        self.executable('node', '#!/bin/bash\nexit 1\n')
        self.executable('curl', '#!/bin/bash\nwhile [[ $# -gt 0 ]]; do if [[ $1 == -o ]]; then shift; printf "corrupt" >"$1"; fi; shift; done\n')
        status, out = self.run_install()
        self.assertNotEqual(status, 0, out)
        self.assertIn('checksum', out.lower())
        self.assertFalse(self.agent.exists())
        self.assertFalse((self.home / '.local/share/pi-modal-setup/install.lock').exists())
    def test_new_pi_mock_npm_ignore_scripts(self):
        (self.bin / 'pi').unlink()
        self.executable('node', '#!/bin/bash\nif [[ ${1:-} != -e ]]; then printf "1.5.0\\n"; fi\n')
        self.executable('npm', '''#!/bin/bash
printf '%s\\n' "$@" >"$HOME/npm-args"
while [[ $# -gt 0 ]]; do
  if [[ $1 == --prefix ]]; then shift; prefix=$1; fi
  shift
done
mkdir -p "$prefix/node_modules/@earendil-works/pi-coding-agent/dist"
printf '// dummy CLI' >"$prefix/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"
''')
        status, out = self.run_install()
        self.assertEqual(status, 0, out)
        self.assertIn('--ignore-scripts', (self.home / 'npm-args').read_text())
        self.assertTrue((self.bin / 'pi').is_symlink())
        self.assertEqual(subprocess.check_output([str(self.bin / 'pi'), '--version'], env=self.env).strip(), b'1.5.0')
    def test_symlink_and_duplicate_json_rejected(self):
        self.agent.mkdir()
        p = self.agent / 'auth.json'
        target = self.home / 'untouched'; target.write_text('{}')
        p.symlink_to(target)
        self.assertNotEqual(self.run_install([])[0], 0)
        self.assertEqual(target.read_text(), '{}')
        p.unlink(); p.write_text('{"a":1,"a":2}')
        self.assertNotEqual(self.run_install([])[0], 0)

if __name__ == '__main__': unittest.main(verbosity=2)
