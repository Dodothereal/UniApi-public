"""Native smoke tests. Only disposable processes created here are terminated."""
import json
import os
from pathlib import Path
import subprocess
import sys

binary = Path(os.environ['UNIAPI_ACTIVITY_BINARY']) if os.environ.get('UNIAPI_ACTIVITY_BINARY') else Path(__file__).resolve().parents[2] / 'data' / 'bin' / 'uniapi-activity'

def call(command, body=None):
    completed = subprocess.run([str(binary), command], input=json.dumps(body) if body is not None else None,
                               capture_output=True, text=True, timeout=12)
    return json.loads(completed.stdout)

sample = call('sample')
assert sample['logicalCpus'] >= 1
assert sample['totalMemory'] > 0
assert 0 <= sample['memoryUsed'] <= sample['totalMemory']
assert sample['processes'] and isinstance(sample['apps'], list)
assert all('cpuNs' in p and 'started' in p for p in sample['processes'])

# Validate real CPU units against the child's own process clock. Synthetic
# nanosecond fixtures cannot catch libproc returning Mach absolute ticks.
worker = '''import sys, time
print("ready", flush=True)
for line in sys.stdin:
    start = time.process_time()
    while time.process_time() - start < 0.25:
        pass
    print(time.process_time() - start, flush=True)
'''
child = subprocess.Popen([sys.executable, '-u', '-c', worker], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    assert child.stdout.readline().strip() == 'ready'
    before = next(p for p in call('sample')['processes'] if p['pid'] == child.pid)
    child.stdin.write('measure\n')
    child.stdin.flush()
    measured_seconds = float(child.stdout.readline())
    after = next(p for p in call('sample')['processes'] if p['pid'] == child.pid)
    helper_seconds = (int(after['cpuNs']) - int(before['cpuNs'])) / 1e9
    assert abs(helper_seconds - measured_seconds) < 0.035, (helper_seconds, measured_seconds)
    print('CPU timebase: helper %.4fs / child process clock %.4fs' % (helper_seconds, measured_seconds))
finally:
    child.stdin.close()
    child.wait(timeout=5)

for bad in [-1, 0, 1, 1.5, 2**40]:
    result = call('terminate', {'mode': 'force', 'targets': [{'pid': bad, 'started': '1:0'}]})
    assert 'error' in result, (bad, result)

for mode in ['quit', 'force']:
    child = subprocess.Popen(['/bin/sleep', '60'])
    try:
        row = next(p for p in call('sample')['processes'] if p['pid'] == child.pid)
        assert row['protectedReason'] is None, row['protectedReason']
        wrong = call('terminate', {'mode': mode, 'targets': [{'pid': child.pid, 'started': '1:0'}]})
        assert 'error' in wrong and child.poll() is None
        sent = call('terminate', {'mode': mode, 'application': False,
                                'targets': [{'pid': child.pid, 'started': row['started']}]})
        assert sent['ok'] is True and sent['requested'] == 1, sent
        child.wait(timeout=5)
        assert child.returncode < 0
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()

own = next(p for p in call('sample')['processes'] if p['pid'] == __import__('os').getpid())
assert own['protectedReason']
denied = call('terminate', {'mode': 'force', 'targets': [{'pid': own['pid'], 'started': own['started']}]})
assert 'error' in denied

# Asking an ordinary sleep process to quit through AppKit cannot succeed.
# This exercises the failure response's boolean without sending a signal.
child = subprocess.Popen(['/bin/sleep', '60'])
try:
    row = next(p for p in call('sample')['processes'] if p['pid'] == child.pid)
    refused = call('terminate', {'mode': 'quit', 'application': True,
                                 'targets': [{'pid': child.pid, 'started': row['started']}]})
    assert refused['ok'] is False and refused['requested'] == 0, refused
    assert child.poll() is None
finally:
    if child.poll() is None:
        child.kill()
    child.wait()
print('Activity native tests passed: live sampling, PID validation, stale identity, ancestor protection, disposable quit and force quit.')
