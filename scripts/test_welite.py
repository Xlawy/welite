"""Run fork-owned checks using an already built KOReader runtime; never build/download."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import io
import zipfile

from emulator import find_runtime

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_REF = '1f4861d3d66549c658e87d8aee96f8977863d836'  # upstream v1.6.0
PREVIOUS_REF = 'c3172f8ffe2e9b3b315741da6ba761012bafc0db'  # WeLite v1.0.4


def upstream_fixture(root, destination, revision=UPSTREAM_REF):
    """Use the immutable upstream ancestor, without downloads or installed plugins."""
    archive = subprocess.check_output(['git', 'archive', '--format=zip', revision,
        'main.lua', '_meta.lua', 'weread', 'integrations', 'fonts', 'icons'], cwd=root)
    with zipfile.ZipFile(io.BytesIO(archive)) as package:
        package.extractall(destination)
    return Path(destination)


def check(root=ROOT):
    mapping = json.loads((root / 'tests/module-map.json').read_text())
    for module, tests in mapping['modules'].items():
        if not (root / module).is_file() or not tests:
            raise ValueError(f'Missing module or tests: {module}')
        for test in tests:
            if not (root / test).is_file():
                raise ValueError(f'Missing test: {module} -> {test}')
    for module in [root / 'main.lua', root / '_meta.lua', *(root / 'welite').rglob('*.lua')]:
        if not module.is_file():
            continue
        if str(module.relative_to(root)) not in mapping['modules'] and str(module.relative_to(root)) not in mapping.get('exemptions',{}):
            raise ValueError(f'Unmapped module: {module}')
    return mapping


def integration(runtime):
    runtime = Path(runtime).resolve()
    if not (runtime / 'spec/runtests').is_file():
        raise ValueError('KOREADER_RUNTIME must contain luajit and spec/runtests')
    plugin = runtime / 'plugins/welite.koplugin'
    existing_link = plugin.is_symlink() and plugin.resolve() == ROOT
    if (plugin.exists() or plugin.is_symlink()) and not existing_link:
        raise ValueError(f'Integration target already exists: {plugin}')
    installed = []
    reports = ROOT / '.dev/reports'
    reports.mkdir(parents=True, exist_ok=True)
    isolated = tempfile.TemporaryDirectory(prefix='welite-native-')
    try:
        if not existing_link:
            plugin.symlink_to(ROOT, target_is_directory=True)
        workspace = Path(isolated.name)
        upstream = upstream_fixture(ROOT, workspace / 'weread.koplugin')
        profile = workspace / 'profile'
        profile.mkdir()
        for source in sorted((ROOT / 'spec/koreader').glob('welite*_spec.lua')):
            target = runtime / 'spec/front/unit' / ('community_' + source.name)
            if target.exists():
                raise ValueError(f'Test target already exists: {target}')
            target.write_bytes(source.read_bytes())
            installed.append(target)
        source=ROOT / 'spec/koreader/weread_plugin_spec.lua'
        target=runtime / 'spec/front/unit/community_plugin_spec.lua'
        if target.exists():
            raise ValueError(f'Test target already exists: {target}')
        target.write_bytes(source.read_bytes()); installed.append(target)
        helper=runtime / 'spec/front/unit/community_welite_native_helper.lua'
        if helper.exists():
            raise ValueError(f'Test helper already exists: {helper}')
        helper.write_bytes((ROOT / 'spec/koreader/welite_native_helper.lua').read_bytes())
        installed.append(helper)
        env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_AUDIODRIVER='dummy',
                 KO_HOME=str(profile), WELITE_UPSTREAM_FIXTURE=str(upstream),
                 XDG_DATA_HOME=str(profile),
                 WELITE_SCREENSHOT=str(reports / 'plugin-smoke.png'))
        subprocess.run(['./spec/runtests','--busted=--helper=' + str(helper.relative_to(runtime)),
                        '-o',str(reports / 'integration.xml'),
                        'front',*[str(p.relative_to(runtime)) for p in installed if p != helper]],
                       cwd=runtime, env=env, check=True)
    finally:
        for target in installed: target.unlink()
        if not existing_link:
            plugin.unlink()
        isolated.cleanup()


def main():
    check()
    if len(sys.argv)>1 and sys.argv[1]=='check': return
    runtime=find_runtime()
    env=dict(os.environ,LUAJIT_BIN=str(Path(runtime).resolve() / 'luajit'))
    subprocess.run(['bash','scripts/check_lua_namespace.sh'],cwd=ROOT,check=True)
    subprocess.run(['bash','scripts/run_lua_specs.sh'],cwd=ROOT,env=env,check=True)
    subprocess.run([sys.executable,'-m','unittest','discover','-s','tests','-p','test_*.py'],cwd=ROOT,env=env,check=True)
    integration(runtime)
    with tempfile.TemporaryDirectory(prefix='welite-updater-') as directory:
        subprocess.run([sys.executable,'scripts/test_updater_simulator.py',
                        '--koreader',str(runtime),'--run-dir',str(Path(directory)/'run')],
                       cwd=ROOT,env=dict(env,SDL_VIDEODRIVER='dummy',SDL_AUDIODRIVER='dummy',
                                        XDG_DATA_HOME=directory),check=True)

if __name__=='__main__': main()
