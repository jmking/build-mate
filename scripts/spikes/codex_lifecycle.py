#!/usr/bin/env python3
"""Manual, real-Codex spike. Never run from the automated test suite.
Only prints protocol facts and scratch-task messages, never account/auth payloads.
"""
import json, pathlib, queue, subprocess, tempfile, threading, time

class Client:
 def __init__(self):
  self.p = subprocess.Popen(['codex','app-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
  self.q=queue.Queue();self.seq=0;self.events=[]
  threading.Thread(target=lambda: [self.q.put(json.loads(s)) for s in self.p.stdout if s.startswith('{')],daemon=True).start()
  self.call('initialize',{'clientInfo':{'name':'build_mate_spike','version':'0.1'},'capabilities':{'experimentalApi':True}})
  self.send({'method':'initialized'})
 def send(self,msg): self.p.stdin.write(json.dumps(msg)+'\n');self.p.stdin.flush()
 def receive(self,timeout=120):
  v=self.q.get(timeout=timeout)
  if v.get('method')=='item/tool/call':
   print('dynamic tool:',v['params']['tool'],flush=True)
   self.send({'id':v['id'],'result':{'contentItems':[{'type':'inputText','text':'Recorded: SPIKE-ORCHID-739'}],'success':True}})
  if v.get('method') in ['thread/tokenUsage/updated','account/rateLimits/updated']: print('notification:',v['method'],flush=True)
  return v
 def call(self,m,p):
  self.seq+=1;i=self.seq;self.send({'id':i,'method':m,'params':p})
  while True:
   v=self.receive()
   if v.get('id')==i and 'method' not in v:
    if 'error' in v: raise RuntimeError(m+': '+json.dumps(v['error']))
    print(m,'OK',flush=True);return v['result']
   self.events.append(v)
 def complete(self):
  deadline=time.monotonic()+180
  while time.monotonic()<deadline:
   v=self.events.pop(0) if self.events else self.receive()
   if v.get('method')=='item/completed' and v['params']['item']['type']=='agentMessage':print('agent:',v['params']['item'].get('text',''),flush=True)
   if v.get('method')=='turn/completed': print('turn status:',v['params']['turn']['status'], 'error:',v['params']['turn'].get('error'),flush=True);return
  raise TimeoutError('turn')
 def close(self):
  self.p.terminate()
  try:self.p.wait(timeout=10)
  except subprocess.TimeoutExpired:self.p.kill();self.p.wait()

def main():
 root=pathlib.Path(tempfile.mkdtemp(prefix='buildmate-spike-'));repo=root/'repo';wt=root/'worktree'
 def git(*args):subprocess.run(['git',*map(str,args)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 git('init','-b','main',repo);git('-C',repo,'-c','user.name=Spike','-c','user.email=spike@example.invalid','commit','--allow-empty','-m','scratch');git('-C',repo,'worktree','add','-b','spike',wt)
 c=Client()
 try:
  r=c.call('account/rateLimits/read',{});print('rate limits available:', bool(r.get('rateLimits')),flush=True)
  models=c.call('model/list',{});model=next((m['id'] for m in models['data'] if m.get('isDefault')),models['data'][0]['id']);print('account default model:',model,flush=True)
  tool={'name':'note','description':'Record a short note.','inputSchema':{'type':'object','properties':{'text':{'type':'string'}},'required':['text'],'additionalProperties':False}}
  r=c.call('thread/start',{'cwd':str(wt),'model':model,'approvalPolicy':'never','sandbox':'workspace-write','config':{'sandbox_workspace_write.network_access':True},'developerInstructions':'Follow the user. Use note when asked. No subagents.','dynamicTools':[tool]});tid=r['thread']['id']
  def turn(text):return c.call('turn/start',{'threadId':tid,'input':[{'type':'text','text':text}],'effort':'low'})
  turn('Call note with text SPIKE-ORCHID-739, remember that marker, then say done.');c.complete()
  turn('What marker did you just record? Reply only with it.');c.complete()
  r=turn('Run sleep 20 in the shell, then say original.');turnid=r['turn']['id']
  c.call('turn/steer',{'threadId':tid,'expectedTurnId':turnid,'input':[{'type':'text','text':'After sleeping say STEERED instead.'}]});c.complete()
  r=turn('Run sleep 60 in the shell then say done.');turnid=r['turn']['id']
  time.sleep(2);c.call('turn/interrupt',{'threadId':tid,'turnId':turnid});c.complete()
  c.close();c=Client()
  c.call('thread/resume',{'threadId':tid,'cwd':str(wt),'developerInstructions':'Follow the user. End every answer with RESUMED. No subagents.'})
  turn('Recall the marker from before the restart. Then call note with that marker.');c.complete()
  turn('Use the shell to write inside.txt here, try writing ../outside.txt (report if sandbox blocks it), and curl -I https://example.com. Do not request escalation. Report results.');c.complete()
  print('scratch:',root,flush=True)
 finally:c.close()
if __name__=='__main__':main()
