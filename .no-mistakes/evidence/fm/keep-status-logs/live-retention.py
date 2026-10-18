import os, pathlib, subprocess, shutil, json
R=pathlib.Path.cwd(); E=pathlib.Path('/root/.no-mistakes/evidence/01M58DRP4QJ8CZFPZC263T2RRJ'); L=R/'.retention-lab'; S=R/'.retention-socket'; C=R/'.retention-code'
assert not L.exists() and not S.exists() and not C.exists()
shutil.copytree(R/'bin',C/'bin')
shutil.copytree(R/'docs',C/'docs')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ('TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND'))}
env.update(FM_HOME=str(L), FM_PROCEVENT_CLAIM_ROOT=str(L/'claims'))
log=open(E/'live-retention.log','w', buffering=1)
def run(*args, expected=0, e=None):
    p=subprocess.run([str(x) for x in args],env=e or env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    log.write('$ '+' '.join(str(x) for x in args)+'\n'+p.stdout+f'[exit {p.returncode}]\n')
    if expected is not None: assert p.returncode==expected, p.stdout
    return p

def put(p,s):
    p.parent.mkdir(parents=True,exist_ok=True); p.write_text(s)
def seed(home,id,text,kind='ship',target=None):
    wt=target or home/'already-returned'/id
    put(home/'state'/f'{id}.meta',f'window=fm-lab-retention:fm-{id}\nendpoint_task_id={id}\nbackend=tmux\nworktree={wt}\nproject={L}/projects/unused\nkind={kind}\nmode=local-only\nspawn_gen=retention-{id}\n'+(f'home={wt}\n' if kind=='secondmate' else ''))
    put(home/'state'/f'{id}.status',f'working: {text}\ndone: {text}\n')
    put(home/'state'/f'{id}.inbox/001.msg',f'pending {text}\n')
    put(home/'state'/f'{id}.inbox/handled/000.msg',f'handled {text}\n')
    put(home/'state'/f'{id}.inbox/.ring-state','transient bookkeeping\n')
    put(home/'state'/f'{id}.turn-ended','')
    run('tmux','-S',S,'new-window','-d','-t','fm-lab-retention:','-n',f'fm-{id}','-c',R,'sleep 600')
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
    p=run('tmux','-S',S,'list-windows','-t','fm-lab-retention','-F','#{window_name}')
    assert f'fm-{id}' not in p.stdout.splitlines()
try:
    run(R/'bin/fm-lab-home.sh','create',L)
    put(L/'config/backlog-backend','manual\n')
    run('tmux','-S',S,'-f','/dev/null','new-session','-d','-s','fm-lab-retention','-n','anchor','-c',R,'sleep 600')
    env['TMUX']=run('tmux','-S',S,'display-message','-p','-t','fm-lab-retention:anchor','#{socket_path},#{pid},0').stdout.strip()
    seed(L,'repeat','first run')
    teardown('repeat'); removed('repeat'); a=archive_matches(L/'data/repeat','first run')
    assert not (L/'state/repeat.status').exists() and not (L/'state/repeat.inbox').exists()
    passed('Local cleanup closes the actual tmux endpoint and archives status plus pending/handled inbox bytes')
    seed(L,'repeat','second run'); teardown('repeat'); removed('repeat')
    b=archive_matches(L/'data/repeat','second run'); archive_matches(L/'data/repeat','first run'); assert a!=b
    passed('Reusing a task ID and message numbers retains both runs separately')
    seed(L,'blocked','archive failure'); put(L/'data/blocked','not a directory\n')
    p=teardown('blocked'); removed('blocked')
    assert 'keeping originals' in p.stdout
    assert (L/'state/blocked.status').read_text()=='working: archive failure\ndone: archive failure\n'
    assert (L/'state/blocked.inbox/001.msg').read_text()=='pending archive failure\n'
    assert (L/'state/blocked.inbox/handled/000.msg').read_text()=='handled archive failure\n'
    passed('A blocked archive destination warns, retains original records, and completes other cleanup')
    seed(L,'linked','symlink failure'); secret=L/'secret'; put(secret,'private sentinel\n')
    (L/'state/linked.inbox/001.msg').unlink(); (L/'state/linked.inbox/001.msg').symlink_to(secret)
    p=teardown('linked'); removed('linked'); assert 'keeping originals' in p.stdout
    assert (L/'state/linked.status').exists() and (L/'state/linked.inbox/001.msg').is_symlink()
    assert not list((L/'data/linked').rglob('001.msg')); assert secret.read_text()=='private sentinel\n'
    passed('A symlinked inbox record is not followed; partial archival retains originals')
    for mode in ['completed','forced','nested','failure']:
        id='mate-'+mode; h=R/('.retention-'+id)
        run(R/'bin/fm-lab-home.sh','create',h); put(h/'.fm-secondmate-home',id+'\n')
        seed(L,id,mode,'secondmate',h)
        seed(h,'child-'+mode,'child '+mode)
        put(h/f'data/child-{mode}/runs/earlier/status.log','earlier status\n')
        put(h/f'data/child-{mode}/runs/earlier/inbox/001.msg','earlier inbox\n')
        put(h/'data/finished/runs/earlier/status.log','already retired\n')
        if mode=='completed':
            (h/f'state/child-{mode}.meta').unlink()
            run('tmux','-S',S,'kill-window','-t',f'fm-lab-retention:fm-child-{mode}')
        if mode=='nested':
            nh=R/'.retention-nested'; run(R/'bin/fm-lab-home.sh','create',nh); put(nh/'.fm-secondmate-home','inner\n')
            seed(h,'inner','inner','secondmate',nh)
            seed(nh,'grandchild','grandchild')
            put(nh/'data/retired-grandchild/runs/old/status.log','old grandchild\n')
        if mode=='failure': put(L/'data'/id/'children','blocked child destination\n')
        p=teardown(id,*([] if mode=='completed' else ['--force'])); removed(id)
        if mode=='failure':
            assert h.exists() and not (h/f'state/child-{mode}.meta').exists()
            assert (h/f'state/child-{mode}.status').exists()
            assert (h/f'state/child-{mode}.inbox/001.msg').exists()
            assert (h/f'data/child-{mode}/runs/earlier/status.log').read_text()=='earlier status\n'
            assert 'keeping originals' in p.stdout
        else:
            assert not h.exists()
            dest=L/'data'/id/'children'/f'child-{mode}'
            archive_matches(dest,'child '+mode)
            assert any(p.read_text()=='earlier status\n' for p in dest.glob('runs/*/status.log'))
            assert any(p.read_text()=='earlier inbox\n' for p in dest.glob('runs/*/inbox/001.msg'))
            assert any(p.read_text()=='already retired\n' for p in (L/'data'/id/'children/finished').glob('runs/*/status.log'))
            if mode=='nested':
                assert not nh.exists()
                dest=L/'data'/id/'children/inner/children'
                archive_matches(dest/'grandchild','grandchild')
                assert any(p.read_text()=='old grandchild\n' for p in (dest/'retired-grandchild').glob('runs/*/status.log'))
        passed('Local secondmate retirement: '+mode+' child records and earlier archives preserved')
    # Capture public persisted record contracts before deleting the disposable lab.
    for root in [L/'data',L/'state/blocked.inbox',L/'state/linked.inbox',R/'.retention-mate-failure']:
        if root.exists(): shutil.copytree(root,E/'retained-records'/(root.relative_to(L) if root.is_relative_to(L) else pathlib.Path(root.name)),symlinks=True,dirs_exist_ok=True)
    shutil.copy2(L/'state/blocked.status',E/'retained-records/blocked-original.status')
    log.write(json.dumps(results,indent=2)+'\n')
finally:
    run('tmux','-S',S,'kill-server',expected=None)
    if S.exists(): S.unlink()
    shutil.rmtree(L,ignore_errors=True)
    shutil.rmtree(C,ignore_errors=True)
    for path in R.glob('.retention-mate-*'): shutil.rmtree(path,ignore_errors=True)
    shutil.rmtree(R/'.retention-nested',ignore_errors=True)
    log.close()
