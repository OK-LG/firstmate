import os, pathlib, shutil, subprocess, tempfile, time
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=root/'.test-phase-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(lab))
children=[]
def run(*args):
    result=subprocess.run(list(args),env=env,text=True,capture_output=True,timeout=20)
    print('$ '+' '.join(args)+'\n'+result.stdout+result.stderr+'exit='+str(result.returncode),flush=True)
    assert result.returncode==0
    return result
try:
    run('bash','bin/fm-lab-home.sh','create',str(lab))
    run('bash','bin/fm-auto-handover.sh','tick')
    assert not list((lab/'state').iterdir())
    print('Without opt-in, tick creates no runtime state.',flush=True)
    (lab/'config/auto-handover').write_text('invalid-directive lab\n')
    run('bash','bin/fm-auto-handover.sh','tick')
    first=(lab/'state/.auto-handover-wake').read_text()
    run('bash','bin/fm-auto-handover.sh','tick')
    assert (lab/'state/.auto-handover-wake').read_text()==first
    print('Operator wake, emitted once over two ticks:\n'+first,flush=True)
    (lab/'config/auto-handover').unlink()
    holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; lock=$(fm_task_set_lock_path "$FM_HOME/state"); fm_lock_try_acquire "$lock" || exit 1; trap \'fm_lock_release "$lock"\' EXIT; echo locked; read -r release'],env=env,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    children.append(holder)
    assert holder.stdout.readline().strip()=='locked'
    errfile=lab/'spawn.stderr'
    with errfile.open('w') as err:
        spawn=subprocess.Popen(['bash','bin/fm-spawn.sh','queued-check',str(lab/'projects/project'),'--scout','--harness','codex','--backend','tmux'],env=env,stdout=subprocess.PIPE,stderr=err,text=True)
        children.append(spawn)
        end=time.monotonic()+15
        while time.monotonic()<end:
            if 'waiting: this home' in errfile.read_text():break
            assert spawn.poll() is None,errfile.read_text()
            time.sleep(.1)
        else:raise AssertionError('spawn never queued: '+errfile.read_text())
        assert spawn.poll() is None
        assert not (lab/'state/queued-check.meta').exists()
        print('Spawn is alive and queued under the held task-set lock; no task metadata was published.',flush=True)
        shutil.rmtree(lab/'state')
        stdout=spawn.communicate(timeout=10)[0]
    stderr=errfile.read_text()
    print('Removed disposable home state during wait.\nSpawn stdout:\n'+stdout+'Spawn stderr:\n'+stderr+'exit='+str(spawn.returncode),flush=True)
    assert spawn.returncode!=0 and 'home state was removed or replaced' in stderr
    assert not (lab/'state').exists()
    holder.communicate('release\n',timeout=10)
    print('Removed state was not recreated. LIVE GUARD SCENARIOS PASSED',flush=True)
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            try:p.communicate(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.communicate()
    shutil.rmtree(lab)
    print('Disposable lab removed.',flush=True)
