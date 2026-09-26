#!/usr/bin/env python3
"""Manual follow-up for explicit sandbox policy and instruction refresh."""
from codex_lifecycle import Client
import pathlib, subprocess, tempfile
root=pathlib.Path(tempfile.mkdtemp(prefix='buildmate-permissions-'));wt=root/'workspace';wt.mkdir()
subprocess.run(['git','init',str(wt)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
c=Client()
try:
 models=c.call('model/list',{})['data']; model=next(m['id'] for m in models if m.get('isDefault'))
 t=c.call('thread/start',{'model':model,'cwd':str(wt),'approvalPolicy':'never','sandbox':'workspace-write','developerInstructions':'Finish each final answer with ORIGINAL.'})['thread']['id']
 policy={'type':'workspaceWrite','writableRoots':[str(wt)],'networkAccess':True,'excludeTmpdirEnvVar':True,'excludeSlashTmp':True}
 def turn(text):
  c.call('turn/start',{'threadId':t,'input':[{'type':'text','text':text}],'sandboxPolicy':policy,'effort':'low'});c.complete()
 turn('Say hello.')
 c.close();c=Client();c.call('thread/resume',{'threadId':t,'cwd':str(wt),'developerInstructions':'Finish each final answer with UPDATED instead of ORIGINAL.'})
 turn('Use the shell: write inside.txt here; attempt ../outside.txt; curl -I https://example.com. Never escalate. Report results.')
 print('outside exists:',(root/'outside.txt').exists(),flush=True)
finally:c.close()
