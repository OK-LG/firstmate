import os, pathlib, subprocess, shutil, json
R=pathlib.Path.cwd(); E=pathlib.Path('/root/.no-mistakes/evidence/01M58DRP4QJ8CZFPZC263T2RRJ'); L=R/'.listener-lab'; S=R/'.listener-socket'; C=R/'.listener-code'
assert not L.exists() and not S.exists() and not C.exists()
shutil.copytree(R/'bin',C/'bin')
shutil.copytree(R/'docs',C/'docs')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
env.update(FM_HOME=str(L), FM_PROCEVENT_CLAIM_ROOT=str(L/'claims'))
log=open(E/'live-listener.log','w', buffering=1)
def run(*args, expected=0, e=None):
    p=subprocess.run([str(x) for x in args],env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    if expected is not None: assert p.returncode==expected, p.stdout
    return p

def put(p,s):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(s)
def seed(home,id,text,kind='ship',target=None):
    wt=target or home/'already-returned'/id
    put(home/'state'/f'{id}.meta',f'window=fm-lab-listener:fm-{id}\nendpoint_task_id={id}\nbackend=tmux\nworktree={wt}\nproject={L}/projects/unused\nkind={kind}\nmode=local-only\nspawn_gen=retention-{id}\n'+(f'home={wt}\n' if kind=='secondmate' else ''))
    put(home/'state'/f'{id}.status',f'working: {text}\ndone: {text}\n')
    put(home/'state'/f'{id}.inbox/001.msg',f'pending {text}\n')
    put(home/'state'/f'{id}.inbox/handled/000.msg',f'handled {text}\n')
    put(home/'state'/f'{id}.inbox/.ring-state','transient bookkeeping\n')
    put(home/'state'/f'{id}.turn-ended','')
    run('tmux','-S',S,'new-window','-d','-t','fm-lab-listener:','-n',f'fm-{id}','-c',R,'sleep 600')
    return {x.relative_to(home/'state'/f'{id}.inbox').as_posix():x.read_bytes() for x in (home/'state'/f'{id}.inbox').rglob('*.msg')}
def archive_matches(dest,text):
    runs=list((dest/'runs').glob('*'))
    hits=[p for p in runs if (p/'status.log').exists() and (p/'status.log').read_text()==f'working: {text}\ndone: {text}\n']
    assert len(hits)==1,(dest,text,runs)
    p=hits[0]
    assert (p/'inbox/001.msg').read_text()==f'pending {text}\n'
    assert (p/'inbox/handled/000.msg').read_text()==f'handled {text}\n'
    assert not (p/'inbox/.ring-state').exists()
    return p
results=[]
def passed(name):
    results.append(name); log.write('OBSERVED: '+name+'\n'); print(name,flush=True)
def teardown(id,*flags): return run(C/'bin/fm-teardown.sh',id,*flags)
def removed(id):
    assert not (L/'state'/f'{id}.meta').exists()
    assert not (L/'state'/f'{id}.turn-ended').exists()
    p=run('tmux','-S',S,'list-windows','-t','fm-lab-listener','-F','#{window_name}')
    assert f'fm-{id}' not in p.stdout.splitlines()
try:
    run(R/'bin/fm-lab-home.sh','create',L)
    run('tmux','-S',S,'-f','/dev/null','new-session','-d','-s','fm-lab-listener','-n','anchor','-c',R,'sleep 600')
    env['TMUX']=run('tmux','-S',S,'display-message','-p','-t','fm-lab-listener:anchor','#{socket_path},#{pid},0').stdout.strip()
    h=R/'.listener-mate'
    run(R/'bin/fm-lab-home.sh','create',h); put(h/'.fm-secondmate-home','listener-mate\n')
    shutil.copytree(R/'bin',h/'bin')
    seed(L,'listener-mate','parent listener','secondmate',h)
    put(h/'state/finished.status','done: listener child history\n')
    put(h/'state/finished.inbox/001.msg','retain this child steer\n')
    put(L/'data/listener-mate/children','archive blocked\n')
    childenv=dict(env,FM_HOME=str(h))
    run(h/'bin/fm-procevent.sh','register','lavish','retention-blocking-source','--','/usr/bin/sleep','600',e=childenv)
    run(h/'bin/fm-procevent.sh','ensure-listening','retention-blocking-source',e=childenv)
    p=run(h/'bin/fm-procevent.sh','list',e=childenv)
    assert 'live' in p.stdout
    assert (L/'claims/retention-blocking-source.claim').exists()
    p=teardown('listener-mate'); removed('listener-mate')
    assert 'keeping originals' in p.stdout and h.exists()
    assert (h/'state/finished.status').read_text()=='done: listener child history\n'
    assert (h/'state/finished.inbox/001.msg').read_text()=='retain this child steer\n'
    assert not (L/'claims/retention-blocking-source.claim').exists()
    assert not list((h/'state/procevent').glob('*.source'))
    p=run(h/'bin/fm-procevent.sh','list',e=childenv)
    assert 'no sources registered' in p.stdout
    passed('Archive failure retains the secondmate home and original child records while sweeping the real live listener and its claim')
    log.write('RETAINED STATUS: '+(h/'state/finished.status').read_text())
    log.write('RETAINED INBOX: '+(h/'state/finished.inbox/001.msg').read_text())
finally:
    if 'h' in globals() and (h/'bin/fm-procevent.sh').exists():
        run(h/'bin/fm-procevent.sh','sweep-home',e=dict(env,FM_HOME=str(h)),expected=None)
    run('tmux','-S',S,'kill-server',expected=None)
    if S.exists(): S.unlink()
    shutil.rmtree(L,ignore_errors=True)
    shutil.rmtree(C,ignore_errors=True)
    if 'h' in globals(): shutil.rmtree(h,ignore_errors=True)
    log.close()
