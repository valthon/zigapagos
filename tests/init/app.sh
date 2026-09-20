#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
BIN="${ZIGAPAGOS_BIN:-$REPO/zig-out/bin/zigapagos}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PROJECT="${APP_STARTER_TEST_PROJECT:-$WORK/project}"
mkdir -p "$PROJECT"
python3 - "$BIN" "$REPO/runtime" "$WORK" "$PROJECT" <<'PY'
import json, os, pathlib, subprocess, sys, shlex, signal, socket, time, urllib.request
binary, runtime, work, project = sys.argv[1:]
work, project = pathlib.Path(work), pathlib.Path(project)
env = dict(os.environ, ZIGAPAGOS_BIN=binary)
env.pop('ZIGAPAGOS_RUNTIME_DIR', None)
def run(args, cwd=project, expected=0, custom_env=env):
    p = subprocess.run(args, cwd=cwd, env=custom_env, capture_output=True, text=True)
    assert p.returncode == expected, (args, p.returncode, p.stdout, p.stderr)
    return p
# Invalid modes and missing runtime fail before writing any project files.
for flags in [['--app'], ['--app', '--minimal'], ['--app', '--multilingual'], ['--app', '--from-astro', 'missing'], ['--minimal', '--runtime-path=anything'], ['--app', '--runtime-path=']]:
    run([binary, 'init', *flags], expected=1)
    assert not list(project.iterdir()), flags
# Source sentinels alone do not make an installable local runtime package.
missing_manifest = work / 'runtime-without-manifest'
(missing_manifest/'src').mkdir(parents=True)
(missing_manifest/'sidecar').mkdir()
(missing_manifest/'src/index.ts').write_text('export {};')
(missing_manifest/'sidecar/render.ts').write_text('export {};')
rejected = run([binary, 'init', '--app', '--runtime-path=' + str(missing_manifest)], expected=1)
assert 'package.json' in rejected.stderr, rejected.stderr
assert not list(project.iterdir()), 'missing runtime manifest wrote scaffold files'
# Invalid manifests must fail before creating any scaffold files, including
# valid JSON with an unusable package shape and a directory posing as a file.
manifest = missing_manifest/'package.json'
for content in ['{invalid JSON', 'null', '[]', '{}', '{"name":42}',
                '{"name":""}', '{"name":"@z/runtime","type":false}',
                '{"name":"@z/runtime","dependencies":[]}',
                '{"name":"@z/runtime","dependencies":{"preact":42}}']:
    manifest.write_text(content, encoding='utf-8')
    rejected = run([binary, 'init', '--app', '--runtime-path=' + str(missing_manifest)], expected=1)
    assert 'package.json' in rejected.stderr, rejected.stderr
    assert not list(project.iterdir()), 'invalid runtime manifest wrote scaffold files'
manifest.unlink(); manifest.mkdir()
rejected = run([binary, 'init', '--app', '--runtime-path=' + str(missing_manifest)], expected=1)
assert 'package.json' in rejected.stderr, rejected.stderr
assert not list(project.iterdir()), 'manifest directory wrote scaffold files'
# Validate the app runtime contract, not just JSON syntax and two sentinels.
contract = work/'runtime-contract'; contract.mkdir()
for directory in ['src', 'sidecar', 'scripts']:
    (contract/directory).mkdir()
    for entry in (pathlib.Path(runtime)/directory).iterdir():
        (contract/directory/entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
original = json.loads((pathlib.Path(runtime)/'package.json').read_text())
def reject_contract(value, diagnostic):
    (contract/'package.json').write_text(json.dumps(value))
    result = run([binary, 'init', '--app', '--runtime-path='+str(contract)], expected=1)
    assert diagnostic in result.stderr, result.stderr
    assert not list(project.iterdir()), 'incomplete runtime wrote scaffold files'
for key in ['exports', 'dependencies']:
    changed = json.loads(json.dumps(original)); del changed[key]
    reject_contract(changed, 'package.json')
for subpath in ['.', './jsx-runtime']:
    changed = json.loads(json.dumps(original)); del changed['exports'][subpath]
    reject_contract(changed, subpath)
    changed['exports'][subpath] = {'require': './src/index.ts'}
    reject_contract(changed, 'importable target')
    changed['exports'][subpath] = './src/nonexistent.ts'
    reject_contract(changed, 'src/nonexistent.ts')
# Existing filesystem paths must not bypass package-export path rules.
(contract/'index.ts').symlink_to(pathlib.Path(runtime)/'src/index.ts')
(contract/'node_modules').mkdir()
(contract/'node_modules/index.ts').symlink_to(pathlib.Path(runtime)/'src/index.ts')
for target in ['./src/../index.ts', './src/./index.ts', './src//index.ts',
               './node_modules/index.ts', './src/%2e%2E/index.ts',
               './%6eode_modules/index.ts', './NODE_MODULES/index.ts',
               './src%2findex.ts', './src%5cindex.ts', r'./src\..\index.ts',
               './src/%00index.ts', './src/%zzindex.ts']:
    for subpath in ['.', './jsx-runtime']:
        changed = json.loads(json.dumps(original))
        changed['exports'][subpath] = target
        reject_contract(changed, 'invalid package target')
# Ordinary URL-encoded file names remain usable.
encoded = json.loads(json.dumps(original))
encoded['exports']['.'] = './src/%69ndex.ts'
(contract/'package.json').write_text(json.dumps(encoded))
encoded_project = work/'encoded-project'; encoded_project.mkdir()
run([binary, 'init', '--app', '--runtime-path='+str(contract)], cwd=encoded_project)
assert (encoded_project/'package.json').is_file()
for dependency in ['preact', 'preact-render-to-string']:
    changed = json.loads(json.dumps(original)); del changed['dependencies'][dependency]
    reject_contract(changed, dependency)
for path in ['src/index.ts', 'src/jsx-runtime.ts', 'src/spa-entry.ts',
             'src/browser-entry.ts', 'src/host.ts', 'src/ssr-env.ts',
             'sidecar/standalone.ts', 'sidecar/render.ts',
             'sidecar/bundle-standalone.ts', 'sidecar/bundle-island.ts',
             'scripts/build-spa-runtime.ts', 'scripts/emit-host-config.ts']:
    entry = contract/path; entry.unlink()
    reject_contract(original, path)
    entry.mkdir()  # An entry-point directory is no more usable than a missing file.
    reject_contract(original, 'regular file')
    entry.rmdir(); entry.symlink_to(pathlib.Path(runtime)/path)
# Conventional conditional exports (including a separate types branch) work.
conditional = json.loads(json.dumps(original))
for subpath in ['.', './jsx-runtime']:
    target = conditional['exports'][subpath]
    conditional['exports'][subpath] = {'types': target, 'import': {'default': target}}
(contract/'package.json').write_text(json.dumps(conditional))
conditional_project = work/'conditional-project'; conditional_project.mkdir()
run([binary, 'init', '--app', '--runtime-path='+str(contract)], cwd=conditional_project)
assert (conditional_project/'package.json').is_file()
# Preserve an explicitly relative runtime path with JSON-significant characters.
quoted = work / 'runtime "quoted"'; quoted.symlink_to(runtime, target_is_directory=True)
probe = work / 'probe'; probe.mkdir()
relative = '../runtime "quoted"'
run([binary, 'init', '--app', '--runtime-path=' + relative], cwd=probe)
assert json.loads((probe/'package.json').read_text())['dependencies']['@z/runtime'] == 'file:' + relative
# npm-style environment discovery also produces a visible relative file link.
run([binary, 'init', '--app'], custom_env=dict(env, ZIGAPAGOS_RUNTIME_DIR=runtime))
package = json.loads((project/'package.json').read_text())
assert package['dependencies']['@z/runtime'].startswith('file:..'), package
run(['bun', 'install'])
run(['bun', 'install', '--frozen-lockfile'])
run(['bun', 'run', 'check'])
run(['bun', 'run', 'build'])
# Execute the generated dev command with the existing hermetic static-server
# fixture. No backend download, application API, or deployed persistence implied.
stub=work/'zigbase'
stub.write_text('#!/bin/sh\nexec bun '+shlex.quote(str(pathlib.Path(runtime).parent/'tests/dev/stub-zigbase.ts'))+' "$@"\n')
stub.chmod(0o755)
with socket.socket() as port_probe:
    port_probe.bind(('127.0.0.1',0))
    port=port_probe.getsockname()[1]
with (work/'dev.log').open('w') as log:
    child=subprocess.Popen(['bun','run','dev','--zigbase='+str(stub),'--no-download','--no-live-reload','--port='+str(port)],cwd=project,env=dict(env,ZIGAPAGOS_DEV_BACKGROUND='0'),stdout=log,stderr=log,start_new_session=True)
    try:
        for attempt in range(150):
            if child.poll() is not None: raise AssertionError((work/'dev.log').read_text())
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/app/new/',timeout=1) as response:
                    if b'Task title' in response.read(): break
            except (OSError, TimeoutError): pass
            time.sleep(0.2)
        else: raise AssertionError((work/'dev.log').read_text())
    finally:
        os.killpg(child.pid,signal.SIGTERM)
        child.wait(timeout=10)
# Dev adds reload/runtime artifacts; restore actual production output for browser checks.
run(['bun','run','build'])

run([binary, 'doctor', 'public', '--strict'])
for route in ['app/index.html','app/new/index.html','app/about/index.html']:
    assert (project/'public'/route).is_file(), route
home=(project/'public/index.html').read_text()
assert '<script' not in home and '/app/' in home
assert 'Loading tasks' in (project/'public/app/index.html').read_text()
assert 'Task title' in (project/'public/app/new/index.html').read_text()
assert (project/'public/spa/app.js').is_file()
# Reruns cannot replace source or the user's package edits.
source=project/'app/storage.ts'; source.write_text(source.read_text()+'\n// user edit\n')
before={p: p.read_bytes() for p in [source, project/'package.json']}
run([binary,'init','--app','--runtime-path='+runtime])
assert all(p.read_bytes()==data for p,data in before.items())
print('PASS: fresh app installs, typechecks, releases and serves its SPA in dev; invalid modes and reruns are safe')
PY
