"""Import a built desktop KOReader runtime and launch this fork in isolation."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = ('luajit', 'koreader.sh', 'reader.lua', 'spec/runtests')


def validate(runtime):
    runtime = Path(runtime).resolve()
    if not all((runtime / name).is_file() for name in REQUIRED):
        raise ValueError(f'Incomplete KOReader runtime: {runtime}; run make migrate-emulator')
    return runtime


def find_runtime(root=ROOT, environ=None):
    env = os.environ if environ is None else environ
    return validate(env.get('KOREADER_RUNTIME') or root / '.dev/emulator')


def migrate(source, root=ROOT):
    source = validate(source)
    destination = root / '.dev/emulator'
    if destination.exists() or destination.is_symlink():
        raise ValueError(f'Refusing to overwrite existing runtime: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Materialize build-tree symlinks. Do not import user data or old plugin/tests.
    def ignore(directory, names):
        relative = Path(directory).relative_to(source)
        excluded = {'.git', '__pycache__'}
        if relative == Path('.'):
            excluded.update({'cache', 'settings', 'screenshots', 'styletweaks', 'ota',
                             'history', 'settings.reader.lua', 'crash.log'})
        if relative == Path('plugins'):
            excluded.update({'welite.koplugin', 'weread.koplugin'})
        if relative == Path('spec/front/unit'):
            excluded.update(name for name in names if name.startswith(('welite_', 'community_')))
        return excluded.intersection(names)
    with tempfile.TemporaryDirectory(prefix='emulator-import-', dir=destination.parent) as temporary:
        stage = Path(temporary) / 'runtime'
        shutil.copytree(source, stage, symlinks=False, ignore=ignore)
        validate(stage)
        (stage / 'welite-import.json').write_text(json.dumps({
            'source': str(source),
            'revision': (source / 'git-rev').read_text().strip() if (source / 'git-rev').exists() else 'unknown',
        }, indent=2) + '\n')
        stage.rename(destination)
    return destination


@contextmanager
def plugin_link(runtime, root=ROOT):
    plugin = runtime / 'plugins/weread.koplugin'
    plugin.parent.mkdir(parents=True, exist_ok=True)
    if plugin.exists() or plugin.is_symlink():
        raise ValueError(f'Plugin target already exists: {plugin}')
    plugin.symlink_to(root.resolve(), target_is_directory=True)
    try:
        yield
    finally:
        if plugin.is_symlink() and plugin.resolve() == root.resolve():
            plugin.unlink()


def launch(root=ROOT, width=600, height=800, dpi=167, environ=None):
    if min(width, height, dpi) <= 0:
        raise ValueError('Screen dimensions and DPI must be positive')
    env = dict(os.environ if environ is None else environ)
    runtime = find_runtime(root, env)
    profile = root / '.dev/profile'
    profile.mkdir(parents=True, exist_ok=True)
    env.update(KO_HOME=str(profile.resolve()), EMULATE_READER_W=str(width),
               EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
    with plugin_link(runtime, root):
        return subprocess.run(['./koreader.sh', '-d'], cwd=runtime, env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['migrate', 'run'])
    parser.add_argument('--source', type=Path)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args()
    if args.command == 'run':
        launch(width=args.width, height=args.height, dpi=args.dpi)
    else:
        source = args.source
        if source is None:
            candidates = list((ROOT.parent / 'welite/.dev/koreader').glob('koreader-emulator-*/koreader'))
            if len(candidates) != 1:
                parser.error('Specify a built runtime with --source /path/to/koreader')
            source = candidates[0]
        print(migrate(source))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'emulator: {error}')
