#!/usr/bin/env python3
"""Wall-clock soak through the actual Swift app, real ASR/Metal and translation/Metal.
Known PCM fixture is replayed as 20 ms frames at 1x, never chunked WAV inference.
Hardware capture and arbitrary lecture accuracy are outside this controlled test.
"""
import argparse,datetime,json,pathlib,subprocess,time,os,signal,statistics
parser=argparse.ArgumentParser();parser.add_argument('--seconds',type=int,default=10800);parser.add_argument('--report',default='soak-report.json');a=parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
report=root/'Tests'/a.report
exe=root/'LumaCaption.app/Contents/MacOS/LumaCaption'
transcripts=pathlib.Path.home()/'Library/Application Support/LumaCaption/Transcripts'
start=time.time();before=set(transcripts.glob('*')) if transcripts.exists() else set()
log=open(report.with_suffix('.log'),'w')
p=subprocess.Popen([str(exe),'--headless','--sample-seconds',str(a.seconds)],stdout=log,stderr=log)
state={'status':'running','requested_seconds':a.seconds,'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'app_pid':p.pid,'scope':'Actual Swift pipeline and Metal models; synthetic PCM at real-time speed; excludes hardware capture','samples':[]}
session=None

def write():
 tmp=report.with_suffix('.tmp');tmp.write_text(json.dumps(state,ensure_ascii=False,indent=2));os.replace(tmp,report)

def processes():
 rows=[]
 for line in subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,%cpu='],text=True).splitlines():
  z=line.split()
  if len(z)==4: rows.append((int(z[0]),int(z[1]),int(z[2]),float(z[3])))
 children={p.pid}
 for _ in range(3): children.update(pid for pid,parent,_,_ in rows if parent in children)
 return [{'pid':pid,'rss_kb':rss,'cpu_percent':cpu} for pid,_,rss,cpu in rows if pid in children]

write()
try:
 while p.poll() is None:
  if not session and transcripts.exists():
   for d in set(transcripts.glob('*'))-before:
    try:
     first=json.loads((d/'transcript.jsonl').read_text().splitlines()[0])
     if first.get('sample_seconds')==a.seconds and first.get('source')=='test_fixture':session=d;state['transcript_directory']=str(d);break
    except (OSError,ValueError,IndexError):pass
  procs=processes();state['samples'].append({'wall_elapsed':round(time.time()-start,2),'processes':procs,'total_rss_kb':sum(x['rss_kb'] for x in procs)})
  state['elapsed_seconds']=round(time.time()-start,2);write()
  if time.time()-start>a.seconds+180:
   state['watchdog_error']='test exceeded duration plus 180 seconds';p.terminate();break
  time.sleep(15)
 p.wait(timeout=45)
except BaseException as e:
 state['watchdog_error']=str(e)
 if p.poll() is None:
  p.terminate()
  try:p.wait(timeout=45)
  except subprocess.TimeoutExpired:p.kill()
state['exit_code']=p.returncode;state['elapsed_seconds']=round(time.time()-start,2)
rows=[]
if session:
 for line in (session/'transcript.jsonl').read_text().splitlines():
  try:rows.append(json.loads(line))
  except ValueError:state['journal_parse_error']=True
translated=[x for x in rows if x.get('type')=='translation'];errors=[x for x in rows if x.get('type') in ('error','translation_error','translation_drain_timeout')]
ends=[x for x in rows if x.get('type')=='session_end'];audio=ends[-1].get('audio_seconds',0) if ends else 0
latencies=sorted(x['latency_seconds'] for x in translated)
state.update({'audio_seconds':audio,'translated_segments':len(translated),'errors':errors,'session_ended':bool(ends),'translation_latency_seconds':{'median':statistics.median(latencies),'p95':latencies[min(len(latencies)-1,int(len(latencies)*0.95))],'max':max(latencies)} if latencies else None})
state['status']='passed' if p.returncode==0 and ends and audio>=a.seconds-0.15 and translated and not errors and not state.get('watchdog_error') and not state.get('journal_parse_error') else 'failed'
state['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();write();log.close()
print(json.dumps({k:v for k,v in state.items() if k!='samples'},ensure_ascii=False,indent=2),flush=True)
