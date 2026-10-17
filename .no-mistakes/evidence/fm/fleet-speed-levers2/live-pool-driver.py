import os,pathlib,subprocess,time,shutil
root=pathlib.Path.cwd(); lab=root/'.q'
assert not lab.exists()
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TMUX','TMUX_PANE','TREEHOUSE_ROOT')}
env.update(FM_HOME=str(lab),FM_TREEHOUSE_LOCK_WAIT_SECS='15',TMUX_TMPDIR=str(lab/'tmux'))
holder=None

def cmd(args,cwd=root,check=True):
 p=subprocess.run(args,cwd=cwd,env=env,text=True,capture_output=True,timeout=40)
 print('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode),flush=True)
 if check:assert p.returncode==0
 return p
try:
 cmd(['bash','bin/fm-lab-home.sh','create',str(lab)])
 (lab/'tmux').mkdir(); project=lab/'projects/p';project.mkdir()
 cmd(['git','init','-q','-b','main',str(project)])
 (project/'hello.txt').write_text('disposable queue validation\n')
 (project/'treehouse.toml').write_text('root = "'+str(lab/'pool')+'"\nmax_trees = 2\n')
 cmd(['git','-C',str(project),'add','.'])
 cmd(['git','-C',str(project),'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','disposable lab'])
 allocated=cmd(['treehouse','get','--lease','--no-fetch'],cwd=project)
 wt=pathlib.Path(allocated.stdout.strip())
 assert str(wt).startswith(str(lab))
 (wt.parent/'.fm-slot-owner').write_text('task=cleanup\nhome='+str(lab)+'\n')
 cmd(['tmux','-L','fm-lab','-f','/dev/null','new-session','-d','-s','pool-lab','-n','control','-c',str(lab)])
 cmd(['tmux','-L','fm-lab','new-window','-d','-t','pool-lab:','-n','fm-cleanup','-c',str(wt)])
 socket=lab/'tmux'/('tmux-'+str(os.getuid()))/'fm-lab'
 env['TMUX']=str(socket)+',0,0'
 (lab/'state/cleanup.meta').write_text('kind=scout\nharness=codex\nbackend=tmux\nwindow=pool-lab:fm-cleanup\nendpoint_task_id=cleanup\nproject='+str(project)+'\nworktree='+str(wt)+'\n')
 holder=subprocess.Popen(['bash','-c','. bin/fm-wake-lib.sh; lock=$(fm_treehouse_project_lock_path "$1") || exit; fm_lock_try_acquire "$lock" || exit 1; trap \'fm_lock_release "$lock"\' EXIT; echo locked; read -r release','_',str(project)],env=env,text=True,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 assert holder.stdout.readline().strip()=='locked'
 print('Concurrent allocator holds the real project lock.',flush=True)
 with (lab/'cleanup.out').open('w') as out,(lab/'cleanup.err').open('w') as err:
  cleanup=subprocess.Popen(['bash','bin/fm-teardown.sh','cleanup','--force'],env=env,stdout=out,stderr=err)
  time.sleep(2)
  assert cleanup.poll() is None, (lab/'cleanup.err').read_text()
  assert (lab/'state/cleanup.meta').exists()
  print('Cleanup remains queued with task metadata preserved after 2 seconds.',flush=True)
  holder.communicate('release\n',timeout=10)
  assert cleanup.wait(timeout=35)==0,(lab/'cleanup.err').read_text()
 print((lab/'cleanup.out').read_text()+(lab/'cleanup.err').read_text(),flush=True)
 assert not (lab/'state/cleanup.meta').exists()
 windows=cmd(['tmux','-L','fm-lab','list-windows','-t','pool-lab','-F','#{window_name}']).stdout
 assert 'fm-cleanup' not in windows and 'control' in windows
 cmd(['treehouse','status'],cwd=project)
 # Reacquiring the exact released slot proves the pool return, not just metadata removal.
 again=cmd(['treehouse','get','--lease','--no-fetch'],cwd=project).stdout.strip()
 assert again==str(wt)
 cmd(['treehouse','return',again,'--force'],cwd=project)
 print('Same Treehouse slot reacquired after queued cleanup; unrelated control pane survived. LIVE POOL QUEUE PASSED',flush=True)
finally:
 if holder is not None and holder.poll() is None:holder.communicate('release\n',timeout=10)
 if (lab/'tmux').exists():subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,capture_output=True)
 if lab.exists():shutil.rmtree(lab)
 print('Private tmux server stopped and disposable lab removed.',flush=True)
