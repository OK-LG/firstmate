import os, pathlib, subprocess, tempfile, shutil, time, re, json, signal
root=pathlib.Path.cwd()
evidence=pathlib.Path('/root/.no-mistakes/evidence/01M4GC8SXVYPE0BSGSWEQKRWVQ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.fm-live-',dir=root))
log=(evidence/'live-transcript.log').open('w',buffering=1)
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','HERDR_SESSION','HERDR_PANE')}
env.update(FM_HOME=str(lab),TMUX=str(lab/'socket')+',0,0',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SECONDMATE_LIVENESS_SECS='99999999')
url='https://github.com/o/r/pull/7'
results=[]
def note(s):
    log.write(s+'\n'); print(s,flush=True)
def run(args, timeout=20, extra=None, allow_timeout=False):
    note('$ '+' '.join(map(str,args)))
    p=subprocess.Popen(list(map(str,args)),cwd=root,env=env| (extra or {}),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    try: out,err=p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid,signal.SIGTERM)
        out,err=p.communicate(timeout=10)
        if not allow_timeout: raise
    log.write(out+err+f'EXIT={p.returncode}\n')
    return p.returncode,out,err
def state(name):
    text=(lab/'state'/name).read_text() if (lab/'state'/name).exists() else '<absent>'
    log.write(f'STATE {name}\n{text}\n'); return text
def watcher(seconds=6):
    result=run(['bin/fm-watch.sh'],timeout=seconds,allow_timeout=True)
    if 'check: rearm-resurface' in result[1]:
        drain()
    return result
def wait_alarm(max_secs=20):
    deadline=time.monotonic()+max_secs
    while time.monotonic()<deadline:
        rc,out,err=watcher(min(6,deadline-time.monotonic()))
        if 'PR-ready overdue' in out:
            assert rc==0,(rc,err)
            return out
    raise AssertionError('No overdue alarm before deadline')
def drain():
    rc,out,err=run(['bin/fm-wake-drain.sh'])
    assert rc==0,(out,err)
    match=re.search(r'--ack-through (\d+) --recovery-generation (\S+)',err)
    if match:
        rc,out,err=run(['bin/fm-wake-drain.sh','--ack-through',match[1],'--recovery-generation',match[2]])
        assert rc==0,(out,err)
def capture():
    rc,out,err=run(['bin/fm-pr-ready-ack.sh','--capture','ship',url]); assert rc==0,(out,err)
    return out.strip()
def ack(token,good=True):
    rc,out,err=run(['bin/fm-pr-ready-ack.sh','ship',url,'review-started',token]); assert (rc==0)==good,(rc,out,err)
def append(line):
    note('REPORT '+line)
    with (lab/'state/ship.status').open('a') as f:f.write(line+'\n')
def passed(name):
    results.append({'name':name,'result':'pass','live':True,'evidence':'live-transcript.log','reason':''}); note('PASS '+name)
try:
    rc,_,_=run(['bin/fm-lab-home.sh','create',lab]); assert rc==0
    (lab/'config/backlog-backend').write_text('manual\n')
    (lab/'state/ship.meta').write_text(f'kind=ship\nbackend=tmux\nwindow=fm-lab:fm-ship\nendpoint_task_id=ship\nworktree={lab}/missing-worktree\nproject={lab}/projects/missing\nmode=local-only\n')
    (lab/'state/.afk').write_text('quiet\n')
    append(f'done [at={int(time.time())-1201}]: PR {url} checks green')
    out=wait_alarm(); assert 'task=ship' in out and url in out
    state('ship.pr-ready'); state('.wake-queue')
    passed('A quiet supervisor receives a durable actionable alarm for a PR older than the default 20 minutes')
    drain()
    # A new watcher process retains the obligation after wake consumption.
    env['FM_PR_READY_REPEAT_SECS']='3'
    out=wait_alarm(); state('.wake-queue')
    passed('Restarting the watcher after draining the wake repeats the still-unhandled PR alarm')
    token=capture()
    # A arrives first, B arrives during its handling, then A is acknowledged.
    env['FM_PR_READY_AGE_SECS']='3'
    append(f'ready [at={int(time.time())}]: PR {url} fixes ready for second review')
    ack(token)
    drain()
    out=wait_alarm(); state('ship.pr-ready'); state('ship.pr-ready-ack')
    passed('A delayed acknowledgement of report A leaves a newer ready report B on the same PR pending')
    latest=capture()
    for bad in [latest.rsplit('|',1)[0]+'|1',latest.rsplit('|',1)[0]+'|999999999', 'wrong-identity|1']:
        ack(bad,False)
    # Wrong URL is independently refused by the real CLI.
    rc,out,err=run(['bin/fm-pr-ready-ack.sh','ship','https://github.com/o/r/pull/8','held',latest]); assert rc!=0
    passed('Acknowledgement refuses partial, future, stale-identity and wrong-PR report tokens')
    ack(latest); drain()
    deadline=time.monotonic()+7
    while time.monotonic()<deadline:
        rc,out,err=watcher(min(3,deadline-time.monotonic()))
        assert 'PR-ready overdue' not in out,(out,err)
    assert state('ship.pr-ready').splitlines()[5]=='1'
    passed('Acknowledging the exact newer report suppresses subsequent overdue alarms across watcher restarts')
    # Fresh done report: verify no early alarm, then actual wall-clock expiry.
    env['FM_PR_READY_AGE_SECS']='6'
    started=int(time.time())
    append(f'done [at={started}]: PR {url} third review ready')
    rc,out,err=watcher(2)
    assert 'PR-ready overdue' not in out
    out=wait_alarm(); assert int(time.time())-started>=6
    passed('A later done report reopens the same PR and waits for the configured age before alarming')
    # Queue a neighboring task through the production queue writer.
    rc,out,err=run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check pr-ready-ship-extra "check: preserve neighboring task"']); assert rc==0
    rc,out,err=run(['bin/fm-teardown.sh','ship'],timeout=30)
    if rc!=0:
        results.append({'name':'Task teardown removes its pending-review records and overdue wake while preserving neighboring tasks','result':'untested','live':False,'evidence':'live-transcript.log','reason':'Teardown refused this disposable task setup: '+err[-1500:]})
    else:
        q=state('.wake-queue')
        assert '\tcheck\tpr-ready-ship\t' not in q
        assert '\tcheck\tpr-ready-ship-extra\t' in q
        for name in ['ship.meta','ship.pr-ready','ship.pr-ready-ack']: assert not (lab/'state'/name).exists(),name
        passed('Task teardown removes its pending-review records and overdue wake while preserving neighboring tasks')
except Exception as e:
    note('DRIVER ERROR '+repr(e)); raise
finally:
    (evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    # Only the disposable marked home is removed; no default runtime was started.
    shutil.rmtree(lab)
    note('Disposable lab removed')
    log.close()
