#!/usr/bin/env python3
"""Interactive regression test for claude-local, driven through a pseudo-terminal.

Creates a throwaway git repo, pre-accepts Claude's workspace-trust dialog for
it in the isolated config, then walks a real session: picker -> model by name
-> banner says websearch=1 -> TUI ready -> one prompt answered -> statusline names
the launched model and shows proxy stats and the 120K-window gauge -> /mcp lists the
websearch server as connected -> double Ctrl-C -> wrapper's post-exit menu -> clean exit.

    test/interactive.py [MODEL]          (default: CLAUDE_LOCAL_MODEL, else the loaded/first llama-server preset, else qwen3-coder:30b)

Exit status is non-zero if any step fails. Transcript: /tmp/claude-local-interactive.bin
"""
import json, os, pty, re, select, shutil, subprocess, sys, tempfile, time, fcntl, termios, struct

def default_model():
    """CLAUDE_LOCAL_MODEL, else the first llama-server preset when that backend is selected, else the Ollama baseline."""
    if os.environ.get('CLAUDE_LOCAL_MODEL'):
        return os.environ['CLAUDE_LOCAL_MODEL']
    cfg = os.path.expanduser(os.environ.get('CLAUDE_LOCAL_CONFIG') or '~/.claude-local')
    try:
        env = subprocess.run(['bash', '-c', f'. "{cfg}/env" 2>/dev/null; echo "$CLAUDE_LOCAL_BACKEND $CLAUDE_LOCAL_PORT"'],
                             capture_output=True, text=True).stdout.split()
        if os.environ.get('CLAUDE_LOCAL_BACKEND', env[0] if env else '') == 'llamaserver':
            port = os.environ.get('CLAUDE_LOCAL_PORT') or (env[1] if len(env) > 1 else '1244')
            import json, urllib.request
            data = json.load(urllib.request.urlopen(f'http://127.0.0.1:{port}/models', timeout=5))['data']
            loaded = [m['id'] for m in data if (m.get('status') or {}).get('value') == 'loaded']
            return (loaded or [m['id'] for m in data])[0]
    except Exception:  # noqa: BLE001
        pass
    return 'qwen3-coder:30b'
MODEL = sys.argv[1] if len(sys.argv) > 1 else default_model()
CONFIG = os.environ.get('CLAUDE_LOCAL_CONFIG', os.path.expanduser('~/.claude-local'))
CLAUDE_JSON = os.path.join(CONFIG, '.claude.json')
LOG_PATH = '/tmp/claude-local-interactive.bin'

repo = tempfile.mkdtemp(prefix='claude-local-itest-')
subprocess.run('git init -q && echo a > a.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm init',
               shell=True, cwd=repo, check=True)
orig = open(CLAUDE_JSON).read() if os.path.exists(CLAUDE_JSON) else None
if orig is not None:   # pre-accept the trust dialog the way the dialog itself records it
    cfg = json.loads(orig)
    cfg.setdefault('projects', {})[repo] = {"hasTrustDialogAccepted": True, "allowedTools": [], "mcpContextUris": [],
        "mcpServers": {}, "enabledMcpjsonServers": [], "disabledMcpjsonServers": [], "hasCompletedProjectOnboarding": True}
    open(CLAUDE_JSON, 'w').write(json.dumps(cfg))
os.chdir(repo)
ANSI = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\x1b[=>]|\r')
log = open(LOG_PATH, 'wb')
env = {k: v for k, v in os.environ.items() if not k.startswith('CLAUDE') or k.startswith('CLAUDE_LOCAL')}
env.update(TERM='xterm-256color', COLUMNS='140', LINES='40', CLAUDE_LOCAL_PROXY_DEBUG='1')
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 140, 0, 0))
p = subprocess.Popen(['claude-local'], stdin=s, stdout=s, stderr=s, env=env, preexec_fn=os.setsid, cwd=os.getcwd())
os.close(s)
buf = ''; seen_text = ''
def expect(pat, timeout):
    global buf, seen_text
    t0 = time.time()
    while time.time() - t0 < timeout:
        if re.search(pat, buf): 
            r = re.search(pat, buf); buf = buf[r.end():]; return True
        rl, _, _ = select.select([m], [], [], 0.5)
        if rl:
            try: data = os.read(m, 65536)
            except OSError: return False
            if not data: return False
            log.write(data); log.flush()
            txt = ANSI.sub('', data.decode('utf-8', 'replace')); buf += txt; seen_text += txt
    return False
def send(sx): os.write(m, sx.encode()); time.sleep(0.3)
def step(name, ok): print(f"{'PASS' if ok else 'FAIL'}  {name}", flush=True); return ok
r = []
r.append(step('picker menu shown',            expect(r'Pick a model number', 20)))
mm = re.search(r'(\d+)\)\s+\[\w+\s*\]\s+' + re.escape(MODEL) + r'\s', seen_text)
num = mm.group(1) if mm else '1'
print(f"      picking entry {num} ({MODEL})"); send(num + '\n')
r.append(step('model accepted + claude start', expect(r'Starting Claude Code: model=' + re.escape(MODEL) + r' ', 60)))
r.append(step('banner: web search MCP on',      expect(r'websearch=1', 10)))
if expect(r'trust\s*this\s*folder', 30):
    send('\x1b[B'); send('\r'); print('      accepted workspace trust dialog')
r.append(step('claude TUI ready',              expect(r'manual\s*mode|for\s*agents|/effort|shortcuts', 120)))
time.sleep(4); send('Reply with exactly the word PTYOK and nothing else.'); time.sleep(1); send('\r')
r.append(step('model answered (assistant output)', expect(r'PTYOK(?!\s*and)', 150)))
r.append(step('statusline names launched model', expect(r'●\s*' + re.escape(MODEL) + r'(?!\S)(?!\s*not loaded)', 40)))
r.append(step('statusline shows proxy stats',  expect(r'tok/s|cache\s*\d+%', 40)))
r.append(step('context gauge uses 120K window', expect(r'/12[01]K', 30)))
send('/mcp'); time.sleep(1); send('\r')
r.append(step('/mcp: websearch server connected', expect(r'websearch[^\n]{0,60}connected|connected[^\n]{0,60}websearch', 20)))
send('\x1b'); time.sleep(0.5); send('\x1b'); time.sleep(0.5)
send('\x03'); r.append(step('first Ctrl-C prompts',        expect(r'Ctrl-C\s*again|again\s*to\s*exit', 10)))
send('\x03'); r.append(step('wrapper survives: post-exit menu', expect(r'models in memory', 30))); send('\r')
r.append(step('leave loaded',                  expect(r'Leaving', 10)))
try: p.wait(timeout=15)
except subprocess.TimeoutExpired: p.kill(); print("FAIL  launcher did not exit")
else: print(f"launcher exit code {p.returncode}")
print(f"{sum(r)}/{len(r)} steps passed")
if orig is not None: open(CLAUDE_JSON, 'w').write(orig)   # drop the temp trust entry
shutil.rmtree(repo, ignore_errors=True)
sys.exit(0 if all(r) and p.returncode == 0 else 1)
