#!/usr/bin/env python3
"""Exercise production sharing against disposable homes and a loopback model only."""
import pathlib, tempfile, json, threading, http.server, time, shutil, subprocess, os, queue, sqlite3, uuid, sys
root = pathlib.Path(__file__).resolve().parents[2]
binary = '/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'
r = pathlib.Path(tempfile.mkdtemp(prefix='switchboard-chat-check-')).resolve()
for name in ['a', 'b', 'c', 'cwd', 'os-home']:
    (r / name).mkdir()
(r / 'synthetic-only').touch()
class RPC:
 def __init__(self,name):
  e={'PATH':os.environ['PATH'],'HOME':str(r/'os-home'),'CODEX_HOME':str(r/name),'TMPDIR':str(r)}
  self.p=subprocess.Popen([binary,'app-server','--stdio','--strict-config'],env=e,cwd=r/'cwd',stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
  self.q=queue.Queue();self.i=0
  def read():
   for line in self.p.stdout:
    try:self.q.put(json.loads(line))
    except ValueError:pass
  threading.Thread(target=read,daemon=True).start()
  self.call('initialize',{'clientInfo':{'name':'switchboard_sharing_probe','version':'0.1'},'capabilities':{'experimentalApi':True}})
  self.p.stdin.write(json.dumps({'method':'initialized'})+'\n');self.p.stdin.flush()
 def call(self,m,params):
  self.i+=1;self.p.stdin.write(json.dumps({'id':self.i,'method':m,'params':params})+'\n');self.p.stdin.flush()
  while True:
   x=self.q.get(timeout=15)
   if x.get('id')==self.i:
    if 'error' in x:raise RuntimeError(m+': '+json.dumps(x['error']))
    return x.get('result')
 def close(self):
  self.p.stdin.close()
  try:self.p.wait(timeout=4)
  except subprocess.TimeoutExpired:self.p.terminate();self.p.wait(timeout=4)
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));requests.append(body)
  answer='SYNTHETIC_REPLY_'+str(len(requests))
  item={'id':'msg_test','type':'message','role':'assistant','status':'completed','content':[{'type':'output_text','text':answer,'annotations':[]}]}
  response={'id':'resp_test','object':'response','created_at':int(time.time()),'status':'completed','model':'fixture','output':[item],'usage':{'input_tokens':1,'output_tokens':1,'total_tokens':2}}
  events=[('response.created',{'response':{**response,'status':'in_progress','output':[]}}),('response.output_item.added',{'output_index':0,'item':{**item,'status':'in_progress','content':[]}}),('response.content_part.added',{'item_id':'msg_test','output_index':0,'content_index':0,'part':{'type':'output_text','text':'','annotations':[]}}),('response.output_text.delta',{'item_id':'msg_test','output_index':0,'content_index':0,'delta':answer}),('response.output_text.done',{'item_id':'msg_test','output_index':0,'content_index':0,'text':answer}),('response.content_part.done',{'item_id':'msg_test','output_index':0,'content_index':0,'part':item['content'][0]}),('response.output_item.done',{'output_index':0,'item':item}),('response.completed',{'response':response})]
  data=''.join('event: '+kind+'\ndata: '+json.dumps({'type':kind,**obj})+'\n\n' for kind,obj in events).encode()
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
config=f'''cli_auth_credentials_store = "file"
model = "fixture"
model_provider = "sharing_probe"
[analytics]
enabled = false
[model_providers.sharing_probe]
name = "Local synthetic test"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
request_max_retries = 0
stream_max_retries = 0
'''
for n in ['a','b','c']:(r/n/'config.toml').write_text(config)
clients=[]
def openrpc(n):
 c=RPC(n);clients.append(c);return c
def close(c):c.close();clients.remove(c)
def project(c,name):return c.call('project/create',{'idempotencyKey':name,'name':'Synthetic shared project','roots':[{'path':str(r/'cwd')}]})['project']['id']
def turn(c,tid,text):
 c.call('turn/start',{'threadId':tid,'input':[{'type':'text','text':text}]})
 deadline=time.time()+30
 while time.time()<deadline:
  event=c.q.get(timeout=30)
  if event.get('method')=='turn/completed':
   status=event['params']['turn']['status'];print('turn status',status)
   if status!='completed': raise RuntimeError('Synthetic turn failed')
   return
 raise RuntimeError('turn timeout')
def share(source, target, expect_failure=False):
    result = subprocess.run([str(root / '.build/debug/SwitchboardChecks'), '--chat-fixture', str(r), source, target], capture_output=True, text=True)
    if expect_failure:
        assert result.returncode != 0, 'Conflicting chat copies must block switching'
    elif result.returncode:
        raise AssertionError(result.stdout + result.stderr)

def make_chat(home, project_id, text, title):
    client = openrpc(home)
    params = {'cwd': str(r / 'cwd'), 'ephemeral': False}
    if project_id:
        params['projectId'] = project_id
    thread = client.call('thread/start', params)['thread']
    turn(client, thread['id'], text)
    client.call('thread/name/set', {'threadId': thread['id'], 'name': title})
    thread = client.call('thread/read', {'threadId': thread['id'], 'includeTurns': False})['thread']
    close(client)
    return thread

def listed(client, archived=False):
    return client.call('thread/list', {'limit': 100, 'modelProviders': [], 'archived': archived})['data']

def items(client, tid):
    return json.dumps(client.call('thread/items/list', {'threadId': tid, 'limit': 100}))

if '--migration' in sys.argv:
    try:
        original = make_chat('a', None, 'MIGRATION_ORIGINAL_CONTEXT', 'Migration source')
        archived = make_chat('a', None, 'MIGRATION_ARCHIVED_CONTEXT', 'Migration archive')
        a = openrpc('a'); a.call('thread/archive', {'threadId': archived['id']}); close(a)
        original_data = pathlib.Path(original['path']).read_bytes()
        for _ in range(2):
            result = subprocess.run([str(root / '.build/debug/AccountRuntimeChecks'), '--migration-fixture', binary,
                str(r/'b'), str(r/'a'), str(r/'backup')], capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
        b = openrpc('b')
        assert {t['id'] for t in listed(b)} == {original['id']}
        assert {t['id'] for t in listed(b, True)} == {archived['id']}
        assert 'MIGRATION_ORIGINAL_CONTEXT' in items(b, original['id'])
        assert pathlib.Path(original['path']).read_bytes() == original_data
        receipt = json.loads((r/'backup/history-import.json').read_text())
        assert set(receipt['importedThreadIDs']) == {original['id'], archived['id']}
        print('PASS: additive migration preserves history, archives, source files, and retry receipts')
    finally:
        for c in clients: c.close()
        server.shutdown(); server.server_close()
        shutil.rmtree(r)
    sys.exit(0)

try:
    a = openrpc('a'); pa = project(a, 'a-project'); close(a)
    b = openrpc('b'); pb = project(b, 'b-project'); close(b)
    ta = make_chat('a', pa, 'A_ORIGINAL_CONTEXT', 'A project chat')
    # Reproduce an existing desktop rollout with an extra filename UUID suffix.
    # Only this disposable database fixture is edited; production never edits SQL.
    original_path = pathlib.Path(ta['path'])
    suffixed = original_path.with_name(original_path.stem + '_' + str(uuid.uuid4()) + '.jsonl')
    original_path.rename(suffixed)
    databases = list((r / 'a').glob('state_*.sqlite'))
    assert len(databases) == 1
    with sqlite3.connect(databases[0]) as db:
        db.execute('UPDATE threads SET rollout_path = ? WHERE id = ?', (str(suffixed), ta['id']))
    ta['path'] = str(suffixed)
    tb = make_chat('b', pb, 'B_ORIGINAL_CONTEXT', 'B project chat')
    private = make_chat('a', None, 'PRIVATE_OUTSIDE_PROJECT', 'Private chat')
    private_data = pathlib.Path(private['path']).read_bytes()
    archived = make_chat('a', pa, 'ARCHIVED_PROJECT_CONTEXT', 'Archived project chat')
    a = openrpc('a'); a.call('thread/archive', {'threadId': archived['id']}); close(a)

    share('a', 'b')
    b = openrpc('b')
    assert {t['id'] for t in listed(b)} == {ta['id'], tb['id']}, 'Project chats visible, standalone excluded'
    assert {t['id'] for t in listed(b, True)} == {archived['id']}, 'Archived project history preserved'
    assert 'A_ORIGINAL_CONTEXT' in items(b, ta['id']), 'History indexed before the user opens the chat'
    assert all(t.get('projectId') == pb for t in listed(b)), 'Target backend project assignment'
    sidebar = json.loads((r / 'b/.codex-global-state.json').read_text())
    local_ids = set(sidebar['local-projects'])
    assert all(sidebar['thread-project-assignments'][tid]['projectId'] in local_ids for tid in [ta['id'], tb['id']])
    b.call('thread/resume', {'threadId': ta['id'], 'excludeTurns': True})
    turn(b, ta['id'], 'B_CONTINUES_A_CHAT')
    assert 'A_ORIGINAL_CONTEXT' in json.dumps(requests[-1])
    close(b)
    print('PASS: Project history, archived chats, sidebar membership, and continuation in B')

    share('b', 'a')
    a = openrpc('a')
    assert 'B_CONTINUES_A_CHAT' in items(a, ta['id']), 'Index refreshed before opening in A'
    assert {t['id'] for t in listed(a)} == {ta['id'], tb['id'], private['id']}
    a.call('thread/resume', {'threadId': ta['id'], 'excludeTurns': True})
    turn(a, ta['id'], 'A_CONTINUES_AFTER_RETURN')
    assert 'B_CONTINUES_A_CHAT' in json.dumps(requests[-1])
    close(a)
    share('a', 'b')
    b = openrpc('b')
    assert 'A_CONTINUES_AFTER_RETURN' in items(b, ta['id'])
    assert len(listed(b)) == 2, 'Repeated switches must not duplicate chats'
    close(b)
    assert pathlib.Path(private['path']).read_bytes() == private_data, 'Standalone history unchanged'
    print('PASS: Round-trip context, index refresh, no duplicates, standalone unchanged')

    share('b', 'c')
    c = openrpc('c')
    assert len(listed(c)) == 2 and len(listed(c, True)) == 1
    assert 'A_CONTINUES_AFTER_RETURN' in items(c, ta['id'])
    close(c)
    print('PASS: Third account inherits existing project history')

    # Replace one target link with a divergent copy. Preserve both; do not pick a winner.
    b = openrpc('b'); copied_path = pathlib.Path(b.call('thread/read', {'threadId': ta['id'], 'includeTurns': False})['thread']['path']); close(b)
    original = copied_path.read_bytes()
    copied_path.unlink(); copied_path.write_bytes(original + b'\n')
    share('a', 'b', expect_failure=True)
    assert copied_path.read_bytes() == original + b'\n'
    assert pathlib.Path(ta['path']).read_bytes() == original
    print('PASS: Divergent copies blocked without overwriting either history')
    print('All project-chat integration checks passed; synthetic model requests:', len(requests))
finally:
    for client in clients:
        client.close()
    server.shutdown()
    shutil.rmtree(r)
