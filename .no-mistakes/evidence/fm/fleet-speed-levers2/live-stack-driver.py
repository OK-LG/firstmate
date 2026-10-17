import json, os, pathlib, signal, socket, subprocess, sys, tempfile, time, urllib.request, shutil
ROOT=pathlib.Path.cwd()
if len(sys.argv)>1 and sys.argv[1]=='server':
    from http.server import BaseHTTPRequestHandler, HTTPServer
    task=sys.argv[2]
    port=int(os.environ['FM_LAB_BASE_PORT'])+int(os.environ['FM_LOCAL_STACK_PORT_OFFSET'])
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            body=json.dumps(dict(task=task,slot=os.environ['FM_LOCAL_STACK_SLOT'],offset=os.environ['FM_LOCAL_STACK_PORT_OFFSET'],port=port)).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        def log_message(self,*args): pass
    server=HTTPServer(('127.0.0.1',port),Handler)
    def stop(*args): server.server_close(); sys.exit(0)
    signal.signal(signal.SIGTERM,stop)
    server.serve_forever()
    sys.exit()
lab=pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.',dir=ROOT/'.test-phase-tmp'))
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(lab),FM_LOCAL_STACK_POLL_SECS='1')
processes=[]
def call(*args):
    p=subprocess.run(['bash',str(ROOT/'bin/fm-local-stack.sh'),*args],env=env,text=True,capture_output=True)
    print('$ fm-local-stack.sh '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode),flush=True)
    return p

def request(port):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/',timeout=.4) as response: return json.load(response)
def until(fn,limit=12):
    end=time.monotonic()+limit
    while time.monotonic()<end:
        try:
            result=fn()
            if result: return result
        except (OSError,ValueError): pass
        time.sleep(.1)
    raise AssertionError('timed out')
def start(task):
    print('$ fm-local-stack.sh run '+task+' -- python3 live-stack-driver.py server '+task,flush=True)
    p=subprocess.Popen(['bash',str(ROOT/'bin/fm-local-stack.sh'),'run',task,'--',sys.executable,__file__,'server',task],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    processes.append(p); return p
def stop(p):
    p.send_signal(signal.SIGTERM)
    out,err=p.communicate(timeout=12)
    print(f'SIGTERM wrapper pid={p.pid}: exit={p.returncode}; stdout={out!r}; stderr={err!r}',flush=True)
    assert p.returncode==143
try:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
    for task in ['a','b','c','d']:
        (lab/'state'/f'{task}.meta').write_text('kind=ship\n')
    for base in range(24000,30000,23):
        sockets=[]
        try:
            for port in [base,base+10]:
                sock=socket.socket(); sockets.append(sock); sock.bind(('127.0.0.1',port))
            break
        except OSError: continue
        finally:
            for sock in sockets: sock.close()
    env['FM_LAB_BASE_PORT']=str(base)
    a=start('a'); assert until(lambda:request(base))['task']=='a'
    b=start('b'); assert until(lambda:request(base+10))['task']=='b'
    for port in [base,base+10]: print(f'HTTP GET 127.0.0.1:{port}: '+json.dumps(request(port)),flush=True)
    assert 'slot 0=a slot 1=b' in call('status').stdout
    assert call('acquire','c').returncode==3
    duplicate=call('run','a','--','true'); assert duplicate.returncode!=0
    c=start('c'); time.sleep(1.3); assert c.poll() is None
    print('Third stack c is queued while both HTTP endpoints remain available.',flush=True)
    assert request(base)['task']=='a' and request(base+10)['task']=='b'
    stop(c); stop(b)
    time.sleep(1.3)
    assert 'slot 0=a slot 1=free' in call('status').stdout
    print('Cancelled waiting stack c did not acquire the newly freed slot.',flush=True)
    b=start('b'); assert until(lambda:request(base+10))['task']=='b'
    d=start('d'); time.sleep(1.2); assert d.poll() is None
    stop(a)
    assert until(lambda:request(base).get('task')=='d')
    print(f'HTTP GET 127.0.0.1:{base} after release: '+json.dumps(request(base)),flush=True)
    assert request(base+10)['task']=='b'
    assert 'slot 0=d slot 1=b' in call('status').stdout
    stop(d); stop(b)
    assert 'slot 0=free slot 1=free' in call('status').stdout
    for port in [base,base+10]:
        with socket.socket() as sock: assert sock.connect_ex(('127.0.0.1',port))!=0
    print('Both stopped HTTP ports refuse connections; both leases are free.',flush=True)
    assert call('run','a','--','bash','-c','exit 7').returncode==7
    assert 'slot 0=free slot 1=free' in call('status').stdout
    print('LIVE STACK SCENARIOS PASSED',flush=True)
finally:
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try:p.communicate(timeout=12)
            except subprocess.TimeoutExpired:p.kill();p.communicate()
    shutil.rmtree(lab)
    print('Disposable lab removed.',flush=True)
