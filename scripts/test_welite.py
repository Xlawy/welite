"""Run fork-owned checks using an already built KOReader runtime; never build/download."""
import json
import os
from pathlib import Path
import subprocess
import sys

from emulator import find_runtime

ROOT = Path(__file__).resolve().parents[1]


def check(root=ROOT):
    mapping = json.loads((root / 'tests/module-map.json').read_text())
    for module, tests in mapping['modules'].items():
        if not (root / module).is_file() or not tests:
            raise ValueError(f'Missing module or tests: {module}')
        for test in tests:
            if not (root / test).is_file():
                raise ValueError(f'Missing test: {module} -> {test}')
    for module in (root / 'weread/ui/welite').glob('*.lua'):
        if str(module.relative_to(root)) not in mapping['modules'] and str(module.relative_to(root)) not in mapping.get('exemptions',{}):
            raise ValueError(f'Unmapped module: {module}')
    return mapping


def integration(runtime):
    runtime = Path(runtime).resolve()
    if not (runtime / 'spec/runtests').is_file():
        raise ValueError('KOREADER_RUNTIME must contain luajit and spec/runtests')
    plugin = runtime / 'plugins/welite.koplugin'
    if plugin.exists() or plugin.is_symlink():
        raise ValueError(f'Integration target already exists: {plugin}')
    installed = []
    reports = ROOT / '.dev/reports'
    reports.mkdir(parents=True, exist_ok=True)
    try:
        plugin.symlink_to(ROOT, target_is_directory=True)
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
                 WELITE_SCREENSHOT=str(reports / 'plugin-smoke.png'))
        subprocess.run(['./spec/runtests','--busted=--helper=' + str(helper.relative_to(runtime)),
                        '-o',str(reports / 'integration.xml'),
                        'front',*[str(p.relative_to(runtime)) for p in installed if p != helper]],
                       cwd=runtime, env=env, check=True)
    finally:
        for target in installed: target.unlink()
        plugin.unlink()


def main():
    check()
    if len(sys.argv)>1 and sys.argv[1]=='check': return
    runtime=find_runtime()
    env=dict(os.environ,LUAJIT_BIN=str(Path(runtime).resolve() / 'luajit'))
    subprocess.run(['bash','scripts/check_lua_namespace.sh'],cwd=ROOT,check=True)
    subprocess.run(['bash','scripts/run_lua_specs.sh'],cwd=ROOT,env=env,check=True)
    subprocess.run([sys.executable,'-m','unittest','discover','-s','tests','-p','test_*.py'],cwd=ROOT,check=True)
    integration(runtime)

if __name__=='__main__': main()
