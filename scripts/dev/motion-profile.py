#!/usr/bin/env python3
"""Repeatable, isolated native motion workload. Never installs or touches live agent data.

Run with a Debug .app built by xcodebuild (do not install it):
  python3 scripts/dev/motion-profile.py --app build/baseline/Build/Products/Debug/'Agent Island.app' --label baseline --runs 3
Trace files and logs remain in ignored build/motion-profile. The driver uses the
app's DEBUG notifications, real hook fixtures and a fake local Claude executable.
No real agent CLI is launched. UI-only checks still require native interaction.
"""
import argparse, json, os, pathlib, shutil, signal, subprocess, tempfile, time

ROOT = pathlib.Path(__file__).resolve().parents[2]

def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--app', required=True, type=pathlib.Path)
    ap.add_argument('--label', required=True)
    ap.add_argument('--runs', type=int, default=3)
    ap.add_argument('--template', default='Animation Hitches')
    ap.add_argument('--drive-only', action='store_true')
    args = ap.parse_args()
    out = ROOT / 'build/motion-profile' / args.label
    out.mkdir(parents=True, exist_ok=True)
    scratch = pathlib.Path(tempfile.mkdtemp(prefix='agent-island-motion-'))
    suffix = '.motion-' + scratch.name
    post = out / 'post'
    source = out / 'post.swift'
    write(source, '''import Foundation
let a = CommandLine.arguments
DistributedNotificationCenter.default().postNotificationName(.init("com.abmbodj.agentisland.debug." + a[2] + a[1]), object: a.count > 3 ? a[3] : "", userInfo: nil, deliverImmediately: true)
''')
    subprocess.run(['swiftc', str(source), '-o', str(post)], check=True)
    # A local stand-in speaks the real stream-json protocol. Fixtures are bounded,
    # repeatable, and do not require network access or authentication.
    fake = scratch / 'bin/claude'
    write(fake, '''#!/usr/bin/env python3
import json,sys,time
sys.stdin.readline()
def emit(x): print(json.dumps(x),flush=True)
emit({'type':'system','subtype':'init','session_id':'motion-chat'})
for i in range(32):
 emit({'type':'assistant','message':{'content':[{'type':'text','text':('Measured fixture %d. '%i)+('A native interface provides immediate feedback. '*12)}]}})
 time.sleep(.08)
emit({'type':'control_request','request_id':'plan','request':{'subtype':'can_use_tool','tool_name':'ExitPlanMode','input':{'plan':'# Motion fixture plan\\n\\n'+('## Verify interaction\\n\\n- Check interruption.\\n- Check Reduce Motion.\\n\\n'*24)}}})
sys.stdin.readline()
emit({'type':'result','subtype':'success','is_error':False,'session_id':'motion-chat'})
''', True)
    home = scratch / 'home'
    home.mkdir()
    cwd = scratch / 'project'
    cwd.mkdir()
    history = scratch / 'history.jsonl'
    rows = []
    for i in range(40):
        rows += [dict(type='user', uuid=f'u{i}', message=dict(content=f'Explain interaction {i}.')),
                 dict(type='assistant', uuid=f'a{i}', message=dict(content=[dict(type='text', text=f'## Interaction {i}\n\n'+('Preserve state during interruptions. '*15))]))]
    rows.append(dict(type='assistant', uuid='tool', message=dict(content=[dict(type='tool_use', id='motion-tool', name='Bash', input=dict(command='printf motion-fixture'))])))
    write(history, ''.join(json.dumps(x)+'\n' for x in rows))
    # Unique bundle identity isolates CFPreferences as well as the scratch support directory.
    fixture_app = scratch / 'Agent Island Motion.app'
    shutil.copytree(args.app.resolve(), fixture_app, symlinks=True)
    bundle_id = 'com.abmbodj.agentisland.motion.' + scratch.name.rsplit('-', 1)[-1].replace('_', '-')
    subprocess.run(['/usr/libexec/PlistBuddy', '-c', 'Set :CFBundleIdentifier ' + bundle_id, str(fixture_app/'Contents/Info.plist')], check=True)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', str(fixture_app)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env = dict(os.environ, CFFIXED_USER_HOME=str(home), AGENT_ISLAND_HOME=str(home), AGENT_ISLAND_SOCKET=str(scratch/'island.sock'), AGENT_ISLAND_DEBUG_ID=suffix, AGENT_ISLAND_TOOLS=str(fake.parent))
    app_log = open(out/'app.log', 'w')
    app = subprocess.Popen([str(fixture_app/'Contents/MacOS/Agent Island'), '-setupShown', 'YES', '-composerDir', str(cwd), '-SUEnableAutomaticChecks', 'NO'], env=env, stdout=app_log, stderr=app_log)
    sleeper = subprocess.Popen(['sleep', '1200'])
    children = []
    def post_cmd(name, arg=''):
        subprocess.run([str(post), suffix, name, arg], check=True)
    hook = args.app.resolve()/'Contents/Helpers/island-hook'
    def fire(name, i, hold=False):
        payload = json.loads((ROOT/'fixtures/claude'/f'{name}.json').read_text())['payload']
        payload.update(session_id=f'motion-{i}', cwd=str(cwd), transcript_path=str(history))
        e = dict(env, ISLAND_SOCKET=str(scratch/'island.sock'), CLAUDE_PID=str(sleeper.pid), TERM_PROGRAM='motion-fixture')
        if hold:
            p = subprocess.Popen([str(hook),'claude'],stdin=subprocess.PIPE,stdout=open(out/'approval.log','a'),stderr=subprocess.DEVNULL,env=e)
            p.stdin.write(json.dumps(payload).encode()); p.stdin.close(); children.append(p)
        else:
            subprocess.run([str(hook),'claude'],input=json.dumps(payload).encode(),stdout=subprocess.DEVNULL,env=e,check=True)
    try:
        deadline = time.monotonic()+12
        while not (scratch/'island.sock').exists():
            if app.poll() is not None: raise RuntimeError('Fixture app exited; inspect app.log')
            if time.monotonic()>deadline: raise RuntimeError('Fixture socket did not appear')
            time.sleep(.05)
        meta = dict(appPid=app.pid, scratch=str(scratch), suffix=suffix, template=args.template, app=str(args.app.resolve()), fixtureApp=str(fixture_app), bundleId=bundle_id)
        write(out/'session.json', json.dumps(meta, indent=2))
        for i in range(4): fire('UserPromptSubmit',i)
        fire('Stop',2)
        for run in range(1,args.runs+1):
            recorder = None
            if not args.drive_only:
                trace = out/f'run-{run}.trace'
                if trace.exists(): raise RuntimeError(f'Trace exists: {trace}, choose a new label')
                log = open(out/f'run-{run}.log','w')
                recorder = subprocess.Popen(['xcrun','xctrace','record','--template',args.template,'--attach',str(app.pid),'--time-limit','26s','--output',str(trace),'--no-prompt'],stdout=log,stderr=log)
                deadline = time.monotonic()+25
                while 'Ctrl-C' not in (out/f'run-{run}.log').read_text():
                    if recorder.poll() is not None: raise RuntimeError('Recorder exited; inspect recording log')
                    if time.monotonic()>deadline: raise RuntimeError('Recorder did not start')
                    time.sleep(.1)
            print(f'{args.label}: workload {run} started',flush=True)
            start=time.monotonic()
            for _ in range(3):
                post_cmd('expand','open');time.sleep(.5)
                post_cmd('expand','collapse');time.sleep(.4)
            for _ in range(12):
                post_cmd('expand','open');time.sleep(.075)
                post_cmd('expand','collapse');time.sleep(.075)
            post_cmd('expand','open');time.sleep(.4)
            post_cmd('tap','motion-0');time.sleep(1.2)
            post_cmd('back');time.sleep(.35)
            post_cmd('newchat');time.sleep(.35)
            post_cmd('compose','claude|Profile native motion with the local fixture.');time.sleep(4)
            post_cmd('back');time.sleep(.4)
            fire('PermissionRequest-Bash',1,hold=True);time.sleep(.4)
            post_cmd('respond','allow');time.sleep(.5)
            post_cmd('respond','undo');time.sleep(.3)
            post_cmd('expand','collapse')
            write(out/f'run-{run}-workload.json',json.dumps(dict(duration=time.monotonic()-start, rapidIntervalMs=75),indent=2))
            if recorder:
                try: recorder.wait(timeout=240)
                except subprocess.TimeoutExpired:
                    recorder.send_signal(signal.SIGINT)
                    try: recorder.wait(timeout=15)
                    except subprocess.TimeoutExpired: recorder.kill(); recorder.wait()
                    raise RuntimeError('xctrace failed to finalize within 240 seconds; trace is not valid evidence')
                if recorder.returncode: raise RuntimeError('xctrace failed; inspect recording log')
            print(f'{args.label}: workload {run} complete',flush=True)
        if args.drive_only:
            print(f'App ready for native UI checks: PID {app.pid}, session {out / "session.json"}',flush=True)
            time.sleep(300)
    finally:
        app.terminate(); sleeper.terminate()
        for p in children:
            if p.poll() is None: p.terminate()
        app.wait(timeout=10); sleeper.wait(timeout=10)
        app_log.close()
        print(f'Fixture artifacts retained under {out}; scratch {scratch}',flush=True)

if __name__ == '__main__': main()
