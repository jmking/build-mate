#!/usr/bin/env python3
"""Manual real-Codex sandbox probe; excluded from tests. No model turn or service calls."""
import os
import pathlib
import subprocess
import tempfile
from codex_lifecycle import Client


def main():
    os.environ['GIT_CONFIG_GLOBAL'] = '/dev/null'
    os.environ['GIT_CONFIG_NOSYSTEM'] = '1'
    git = subprocess.check_output(['xcrun', '--find', 'git'], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='buildmate-git-permissions-') as directory:
        root = pathlib.Path(directory).resolve()
        repo, work = root / 'repo', root / 'worktree'

        def local(*args, cwd=None):
            return subprocess.check_output([git, *map(str, args)], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()

        local('init', '-b', 'main', repo)
        local('-c', 'user.name=Probe', '-c', 'user.email=probe@example.invalid', 'commit', '--allow-empty', '-m', 'Initial', cwd=repo)
        local('worktree', 'add', '-b', 'buildmate/task', work, cwd=repo)
        (work / 'feature.txt').write_text('change\n')
        private, common, objects, ref, log = local('rev-parse', '--path-format=absolute', '--git-dir', '--git-common-dir',
            '--git-path', 'objects', '--git-path', 'refs/heads/buildmate/task', '--git-path', 'logs/refs/heads/buildmate/task', cwd=work).splitlines()
        roots = [str(work), private, objects, ref, ref + '.lock', log, log + '.lock']
        client = Client()
        try:
            def command(argv, writable):
                result = client.call('command/exec', {'cwd': str(work), 'command': argv, 'timeoutMs': 10000,
                    'sandboxPolicy': {'type': 'workspaceWrite', 'writableRoots': writable,
                        'networkAccess': False, 'excludeTmpdirEnvVar': True, 'excludeSlashTmp': True}})
                return result['exitCode']

            assert command([git, 'add', 'feature.txt'], [str(work)]) != 0
            assert command([git, 'add', 'feature.txt'], roots) == 0
            assert command([git, '-c', 'user.name=Probe', '-c', 'user.email=probe@example.invalid', '-c', 'maintenance.auto=false',
                'commit', '-m', 'Implementation'], roots) == 0
            for target in [repo / 'forbidden', pathlib.Path(common) / 'config', pathlib.Path(common) / 'hooks/forbidden']:
                assert command(['/usr/bin/touch', str(target)], roots) != 0
            assert command([git, 'update-ref', 'refs/heads/main', 'HEAD'], roots) != 0
            assert not local('status', '--porcelain', cwd=work)
            assert not local('status', '--porcelain', cwd=repo)
            assert local('log', '-1', '--format=%s', cwd=repo) == 'Initial'
            print('PASS: old policy denies staging; scoped policy permits commit and blocks clone/config/hooks/main-ref writes.')
        finally:
            client.close()


if __name__ == '__main__':
    main()
