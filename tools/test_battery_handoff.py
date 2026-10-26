"""Charging upgrade fixtures: all administrator/launchd/validator commands are fake."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CANDIDATE = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,plistlib,stat,sys
root=pathlib.Path(os.environ['FIXTURE_ROOT']); command=sys.argv[1]; args=sys.argv[2:]
def fail(): sys.exit(1)
def emit(value): print(json.dumps(value,sort_keys=True))
def tick():
 n=int((root/'clock').read_text())+1000; (root/'clock').write_text(str(n)); return n
def identity():
 value=json.loads((root/'process').read_text())
 return {'pid':value['pid'],'birthMicros':value['birth'],'instance':str(value['pid'])+':0:'+str(value['birth'])} if value['pid'] else {'pid':0,'birthMicros':0,'instance':'absent'}
def protected(file,kind,optional=False):
 if not file.exists():
  if optional: return 'absent'
  fail()
 info=file.lstat(); uid=503 if kind=='target' else 0
 if os.environ.get('FIXTURE_BAD_UID')==kind: uid=503 if kind!='target' else 504
 private=kind in ('target','journal'); forbidden=0o077 if private else 0o022
 if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or (info.st_mode & forbidden) or uid!=(503 if kind=='target' else 0) or os.environ.get('FIXTURE_BAD_ACL')==kind: fail()
 data=file.read_bytes(); digest=hashlib.sha256(data).hexdigest()
 return str(info.st_ino)+':'+str(uid)+':'+str(info.st_mode)+':'+str(info.st_size)+':'+str(info.st_mtime_ns)+':'+str(info.st_ctime_ns)+':'+digest
if command=='handoff-clock': emit({'micros':tick()})
elif command=='check-handoff':
 if os.environ.get('FIXTURE_REJECT_ADMISSION')=='1': fail()
 text=(pathlib.Path(args[0])/'target').read_text().strip()
 emit({'compatible':True,'protocol':1,'owner':int(args[1]),'target':0 if text=='off' else int(text)})
elif command=='handoff-files':
 directory,binary,plist=map(pathlib.Path,args[:3]); label=args[3]
 stamps={'protocol':2,'binary':protected(binary,'binary'),'plist':protected(plist,'plist'),'target':protected(directory/'target','target'),'journal':protected(directory/'preferences.plist','journal',True)}
 protected(directory/'state.json','report',True)
 value=plistlib.loads(plist.read_bytes())
 if value['Label']!=label or value['ProgramArguments']!=[str(binary),'daemon',str(directory/'target')] or value.get('KeepAlive') is not True: fail()
 stamps['binarySHA256']=hashlib.sha256(binary.read_bytes()).hexdigest(); emit(stamps)
elif command=='handoff-loaded':
 directory,binary,label=args[:3]; text=sys.stdin.read(); process=json.loads((root/'process').read_text())
 if ('program = '+binary+'\n') not in text or os.environ.get('FIXTURE_WRONG_PROCESS_UID')=='1' or os.environ.get('FIXTURE_WRONG_PROCESS_ARGV')=='1': fail()
 if process['pid'] and ('pid = '+str(process['pid'])+'\n') not in text: fail()
 emit(identity())
elif command=='handoff-ack':
 directory,binary,pid,earliest,digest,target,mode=args
 value=json.loads((pathlib.Path(directory)/'state.json').read_bytes()); process=json.loads((root/'process').read_text()); current=identity()
 # One immutable parse, before checking any field, mirrors the production API.
 if not process['pid'] or int(pid)!=process['pid'] or value['pid']!=process['pid'] or process['birth']<int(earliest) or value['target']!=int(target): fail()
 legacy=mode=='legacy' and value.get('runtime') is None
 floor=((max(process['birth'],int(earliest))+(999999 if legacy else 999))//(1000000 if legacy else 1000))*(1000 if legacy else 1)
 if value['updatedAt']<floor: fail()
 if not legacy and (value.get('runtime')!='swift' or value.get('binarySHA256')!=digest or value.get('processStartedAtMicros')!=process['birth'] or not value.get('instanceID')): fail()
 if int(target)==0:
  if value['state']!='off': fail()
 elif value.get('nativeLimit')!=int(target) or value['state'] not in ('inhibiting','charging','on-battery','telemetry-unavailable'): fail()
 if os.environ.get('FIXTURE_LATE_TARGET')=='1' and not (root/'late-target').exists():
  (root/'state/target').write_text('55\n'); (root/'late-target').touch()
 if os.environ.get('FIXTURE_ACK_INSTANCE_DRIFT')=='1' and not (root/'ack-drift').exists():
  process['pid']+=1; process['birth']=tick(); (root/'process').write_text(json.dumps(process)); (root/'ack-drift').touch()
 if os.environ.get('FIXTURE_LATE_BINARY_PHASE')==mode and not (root/'binary-drift').exists():
  pathlib.Path(binary).write_bytes(b'operator replacement fixture'); (root/'binary-drift').touch()
 emit(current)
else: fail()
'''
LAUNCHCTL = r'''#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys
root=pathlib.Path(os.environ['FIXTURE_ROOT']); args=sys.argv[1:]
with (root/'calls').open('a') as output: output.write(json.dumps(args)+'\n')
process=json.loads((root/'process').read_text())
if args[0]=='print':
 program='/unrelated/root-controller' if os.environ.get('FIXTURE_WRONG_JOB')=='1' else str(root/'tools/controller')
 print('system/fixture.battery = {\n program = '+program+'\n arguments = {\n '+str(root/'tools/controller')+'\n daemon\n '+str(root/'state/target')+'\n }')
 if process['pid']: print(' pid = '+str(process['pid']))
 print('}'); sys.exit(0)
if args[0]=='kill':
 assert args[1]=='SIGKILL'
 if os.environ.get('FIXTURE_SAME_PID_REPORT')=='1': sys.exit(0)
 if os.environ.get('FIXTURE_FAIL_RECOVERY_KILL')=='1' and (root/'tools/controller').read_bytes()==b'legacy controller fixture': sys.exit(1)
 if os.environ.get('FIXTURE_CONCURRENT_TARGET')=='1' and not (root/'target-changed').exists():
  (root/'state/target').write_text('55\n'); (root/'target-changed').touch()
 (root/'last-pid').write_text(str(process['pid'])); process['pid']=0
 (root/'process').write_text(json.dumps(process)); sys.exit(0)
if args[0]=='kickstart':
 if os.environ.get('FIXTURE_FAIL_KICKSTART')=='1': sys.exit(1)
 if os.environ.get('FIXTURE_SAME_PID_REPORT')=='1': print(process['pid']); sys.exit(0)
 data=(root/'tools/controller').read_bytes()
 if os.environ.get('FIXTURE_ABSENT_START')=='1' and data!=b'legacy controller fixture': sys.exit(0)
 if process['pid']: print(process['pid']); sys.exit(0)
 process['pid']=int((root/'last-pid').read_text())+1
 process['birth']=int((root/'clock').read_text())+1000; (root/'clock').write_text(str(process['birth']))
 (root/'process').write_text(json.dumps(process)); (root/'last-pid').write_text(str(process['pid']))
 current=(root/'state/target').read_text().strip(); target=0 if current=='off' else int(current)
 updated=(process['birth']+999)//1000
 report={'version':2,'pid':process['pid'],'updatedAt':updated,'target':target,'nativeLimit':target,'state':'off' if target==0 else 'inhibiting','backend':'PowerUI preferences'}
 if data!=b'legacy controller fixture':
  report.update(runtime='swift',binarySHA256=hashlib.sha256(data).hexdigest() if os.environ.get('FIXTURE_BAD_NEW_IDENTITY')!='1' else 'wrong',processStartedAtMicros=process['birth'],instanceID='00000000-0000-0000-0000-'+str(process['pid']).zfill(12))
  if os.environ.get('FIXTURE_FIRST_REPORT_FAILURE')=='1': sys.exit(0)
 else:
  report['updatedAt']=(process['birth']+999999)//1000000*1000
 (root/'state/state.json').write_text(json.dumps(report)); print(process['pid']); sys.exit(0)
raise RuntimeError('Unexpected fake launchctl '+repr(args))
'''

@unittest.skipUnless(os.name == 'posix', 'Root controller shell fixtures require POSIX')
class BatteryHandoffTests(unittest.TestCase):
    def fixture(self, temporary):
        root=Path(temporary)
        for name in ('state','tools','commands'): (root/name).mkdir()
        (root/'state/target').write_text('50\n'); (root/'state/target').chmod(0o600)
        (root/'state/preferences.plist').write_bytes(plistlib.dumps({'target':50,'nativeLimit':80,'old':{'mclLimitValue':80},'user':'current','host':'any'})); (root/'state/preferences.plist').chmod(0o600)
        installed=root/'tools/controller'; installed.write_bytes(b'legacy controller fixture'); installed.chmod(0o755)
        (root/'controller.plist').write_bytes(plistlib.dumps({'Label':'fixture.battery','ProgramArguments':[str(installed),'daemon',str(root/'state/target')],'KeepAlive':True,'RunAtLoad':True}))
        (root/'controller.plist').chmod(0o644)
        source=root/'candidate'; source.write_text(CANDIDATE); source.chmod(0o755)
        (root/'clock').write_text('1700000000000000'); (root/'last-pid').write_text('1111')
        (root/'process').write_text(json.dumps({'pid':1111,'birth':1699999990000000}))
        environment=os.environ.copy(); environment.update(PATH=str(root/'commands')+os.pathsep+environment['PATH'],FIXTURE_ROOT=str(root))
        scripts={
            'id':'#!/bin/bash\necho 0\n', 'codesign':'#!/bin/bash\nexit 0\n', 'sleep':'#!/bin/bash\nexit 0\n',
            'install':r'''#!/usr/bin/env python3
import os,pathlib,shutil,sys
source,dest=map(pathlib.Path,sys.argv[-2:])
if os.environ.get('FIXTURE_FAIL_RESTORE')=='1' and source.name=='previous-binary': sys.exit(1)
shutil.copyfile(source,dest); dest.chmod(0o755)
''',
            'plutil':r'''#!/usr/bin/env python3
import json,pathlib,plistlib,sys
if sys.argv[1]!='-extract': sys.exit(1)
data=pathlib.Path(sys.argv[-1]).read_bytes()
try: value=json.loads(data)
except ValueError: value=plistlib.loads(data)
for key in sys.argv[2].split('.'): value=value[int(key)] if isinstance(value,list) else value[key]
print(str(value).lower() if isinstance(value,bool) else value)
''', 'launchctl':LAUNCHCTL,
        }
        for name,body in scripts.items(): file=root/'commands'/name; file.write_text(body); file.chmod(0o755)
        return root,environment
    def run_handoff(self, root, environment):
        args=[str(root/'candidate'),str(root/'state'),str(root/'tools/controller'),str(root/'controller.plist'),'fixture.battery','503','2']
        return subprocess.run(['bash','-c','source "$1"; shift; uniapi_battery_handoff "$@"','fixture',str(ROOT/'native/swift/tools/battery-handoff.sh'),*args],env=environment,capture_output=True,text=True,timeout=30)
    def snapshot(self, root):
        return {str(file.relative_to(root)):(file.read_bytes(),file.stat().st_ino,file.stat().st_mode) for file in (root/'state/target',root/'state/preferences.plist',root/'controller.plist')}
    def calls(self, root): return [json.loads(line) for line in (root/'calls').read_text().splitlines()] if (root/'calls').exists() else []
    def test_exact_replacement_preserves_target_owner_inode_journal_and_job(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); before=self.snapshot(root); result=self.run_handoff(root,env)
            self.assertEqual(result.returncode,0,result.stderr); self.assertEqual(self.snapshot(root),before)
            self.assertEqual((root/'tools/controller').read_bytes(),(root/'candidate').read_bytes())
            self.assertIn(['kill','SIGKILL','system/fixture.battery'],self.calls(root))
            self.assertTrue(all('SIGTERM' not in c and 'bootout' not in c and '-k' not in c for c in self.calls(root)))
    def test_incompatible_admission_never_replaces_or_signals_prior_controller(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_REJECT_ADMISSION']='1'; before=self.snapshot(root)
            result=self.run_handoff(root,env); self.assertNotEqual(result.returncode,0); self.assertEqual(self.snapshot(root),before)
            self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture'); self.assertFalse(any(c[0]=='kill' for c in self.calls(root)))
    def test_unknown_loaded_job_or_process_identity_is_refused_before_signal(self):
        for flag in ('FIXTURE_WRONG_JOB','FIXTURE_WRONG_PROCESS_UID','FIXTURE_WRONG_PROCESS_ARGV'):
            with self.subTest(flag=flag),tempfile.TemporaryDirectory() as temporary:
                root,env=self.fixture(temporary); env[flag]='1'; result=self.run_handoff(root,env)
                self.assertNotEqual(result.returncode,0); self.assertFalse(any(c[0]=='kill' for c in self.calls(root)))
                self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture')
    def test_unsafe_prior_files_and_acl_are_refused_before_backup_or_signal(self):
        for kind in ('binary','plist','journal','report'):
            for flag in ('FIXTURE_BAD_UID','FIXTURE_BAD_ACL'):
                with self.subTest(kind=kind,flag=flag),tempfile.TemporaryDirectory() as temporary:
                    root,env=self.fixture(temporary)
                    if kind=='report': (root/'state/state.json').write_text('{}'); (root/'state/state.json').chmod(0o644)
                    env[flag]=kind; result=self.run_handoff(root,env)
                    self.assertNotEqual(result.returncode,0); self.assertFalse(any(c[0]=='kill' for c in self.calls(root)))
                    self.assertFalse(list((root/'state').glob('.upgrade.*/previous-binary')))
        for name in ('tools/controller','controller.plist'):
            with tempfile.TemporaryDirectory() as temporary:
                root,env=self.fixture(temporary); (root/name).chmod(0o777); result=self.run_handoff(root,env)
                self.assertNotEqual(result.returncode,0); self.assertFalse(any(c[0]=='kill' for c in self.calls(root)))
    def test_wrong_executable_heartbeat_restores_only_binary_and_proves_fresh_legacy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_BAD_NEW_IDENTITY']='1'; before=self.snapshot(root); result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture'); self.assertEqual(self.snapshot(root),before)
            self.assertIn('fresh previous controller instance is confirmed',result.stderr); self.assertGreater(json.loads((root/'process').read_text())['pid'],1112)
    def test_failed_recovery_signal_cannot_claim_previous_controller_running(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env.update(FIXTURE_BAD_NEW_IDENTITY='1',FIXTURE_FAIL_RECOVERY_KILL='1'); result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertIn('recovery is unconfirmed',result.stderr); self.assertNotIn('instance is confirmed',result.stderr)
            self.assertEqual(json.loads((root/'process').read_text())['pid'],1112)
    def test_failed_kickstart_propagates_and_retains_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_FAIL_KICKSTART']='1'; result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertIn('recovery is unconfirmed',result.stderr)
            self.assertTrue(list((root/'state').glob('.upgrade.*/previous-binary')))
    def test_same_sha_unchanged_process_and_report_cannot_confirm_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); (root/'tools/controller').write_bytes((root/'candidate').read_bytes()); env['FIXTURE_SAME_PID_REPORT']='1'
            (root/'state/state.json').write_text(json.dumps({'version':2,'pid':1111,'updatedAt':1700000000000,'runtime':'swift','binarySHA256':hashlib.sha256((root/'candidate').read_bytes()).hexdigest(),'target':50,'nativeLimit':50,'state':'inhibiting'})); (root/'state/state.json').chmod(0o644)
            result=self.run_handoff(root,env); self.assertNotEqual(result.returncode,0); self.assertNotIn('Charging controller upgraded',result.stdout)
    def test_drift_during_acknowledgement_preserves_new_operator_target(self):
        for flag in ('FIXTURE_CONCURRENT_TARGET','FIXTURE_LATE_TARGET'):
            with self.subTest(flag=flag),tempfile.TemporaryDirectory() as temporary:
                root,env=self.fixture(temporary); env[flag]='1'; before=(root/'state/preferences.plist').read_bytes(); result=self.run_handoff(root,env)
                self.assertNotEqual(result.returncode,0); self.assertEqual((root/'state/target').read_text(),'55\n'); self.assertEqual((root/'state/preferences.plist').read_bytes(),before)
                self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture')
    def test_changed_process_after_immutable_report_is_not_confirmed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_ACK_INSTANCE_DRIFT']='1'; result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertNotIn('Charging controller upgraded',result.stdout)
    def test_late_upgrade_binary_drift_is_not_committed_or_replaced_by_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_LATE_BINARY_PHASE']='swift'; before=self.snapshot(root)
            result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertNotIn('Charging controller upgraded',result.stdout)
            self.assertEqual((root/'tools/controller').read_bytes(),b'operator replacement fixture')
            self.assertEqual(self.snapshot(root),before)
            self.assertEqual(sum(c[0]=='kill' for c in self.calls(root)),1)
            self.assertIn('recovery is unconfirmed',result.stderr)
    def test_late_recovery_binary_drift_cannot_claim_a_restored_instance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env.update(FIXTURE_LATE_BINARY_PHASE='legacy',FIXTURE_BAD_NEW_IDENTITY='1'); before=self.snapshot(root)
            result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertNotIn('instance is confirmed',result.stderr)
            self.assertEqual((root/'tools/controller').read_bytes(),b'operator replacement fixture')
            self.assertEqual(self.snapshot(root),before)
            self.assertEqual(sum(c[0]=='kill' for c in self.calls(root)),2)
            self.assertIn('recovery is unconfirmed',result.stderr)
    def test_crashed_replacement_without_pid_still_restores_owned_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_ABSENT_START']='1'; before=self.snapshot(root); result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture'); self.assertEqual(self.snapshot(root),before)
            self.assertIn('fresh previous controller instance is confirmed',result.stderr)
    def test_failed_first_report_retains_policy_files_and_confirms_fresh_binary_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env['FIXTURE_FIRST_REPORT_FAILURE']='1'; before=self.snapshot(root)
            result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertEqual(self.snapshot(root),before)
            self.assertEqual((root/'tools/controller').read_bytes(),b'legacy controller fixture')
            self.assertIn('fresh previous controller instance is confirmed',result.stderr)
            self.assertNotIn('Charging controller upgraded',result.stdout)
    def test_failed_binary_recovery_is_honest_and_backup_is_retained(self):
        with tempfile.TemporaryDirectory() as temporary:
            root,env=self.fixture(temporary); env.update(FIXTURE_BAD_NEW_IDENTITY='1',FIXTURE_FAIL_RESTORE='1'); before=self.snapshot(root); result=self.run_handoff(root,env)
            self.assertNotEqual(result.returncode,0); self.assertEqual(self.snapshot(root),before); self.assertIn('recovery is unconfirmed',result.stderr)
            self.assertTrue(list((root/'state').glob('.upgrade.*/previous-binary')))

if __name__=='__main__': unittest.main()
