import subprocess, time, json, os, sys, re, glob, resource
D = os.path.dirname(os.path.abspath(__file__))
M = os.path.expanduser('~/.local/share/whisper')
GROQ = json.load(open(os.path.expanduser('~/.config/yapless/config.json')))['whisper']['groqApiKey']
EL = os.environ['ELEVENLABS_API_KEY']

def timed(cmd, env=None):
    t = time.time()
    p = subprocess.run(['/usr/bin/time', '-l'] + cmd, capture_output=True, text=True, env=env)
    wall = time.time() - t
    m = re.search(r'(\d+)\s+maximum resident set size', p.stderr)
    rss = int(m.group(1)) / 2**30 if m else None
    return p.stdout, wall, rss, p

def wc(model, lang='auto'):
    def run(f, lng):
        out, w, r, p = timed(['whisper-cli', '-m', f'{M}/{model}', '-f', f, '-nt', '-np', '-l', lang])
        return out.strip(), w, r
    return run

def parakeet(f, lng):
    out, w, r, p = timed(['parakeet-cli', '-m', f'{M}/ggml-parakeet-tdt-0.6b-v3-q8_0.bin', '-f', f, '-np'])
    return out.strip(), w, r

def apple(f, lng):
    env = dict(os.environ)
    loc = 'en_US'
    if lng == 'ru':
        env['SA_DICTATION'] = '1'; loc = 'ru_RU'
    out, w, r, p = timed([f'{D}/apple/sa', f, loc], env=env)
    if p.returncode: out = ''
    return out.strip(), w, r

def groq(model):
    def run(f, lng):
        out, w, r, p = timed(['curl', '-s', 'https://api.groq.com/openai/v1/audio/transcriptions', '-H', f'Authorization: Bearer {GROQ}',
                              '-F', f'file=@{f}', '-F', f'model={model}', '-F', 'response_format=text'])
        return out.strip(), w, None
    return run

def scribe(f, lng):
    out, w, r, p = timed(['curl', '-s', 'https://api.elevenlabs.io/v1/speech-to-text', '-H', f'xi-api-key: {EL}',
                          '-F', f'file=@{f}', '-F', 'model_id=scribe_v2', '-F', 'tag_audio_events=false'])
    try: out = json.loads(out)['text']
    except Exception: out = 'ERR ' + out[:200]
    return out.strip(), w, None

ENGINES = {
  'wc-base(current)': wc('ggml-base.bin'),
  'wc-small': wc('ggml-small.bin'),
  'wc-turbo-q5': wc('ggml-large-v3-turbo-q5_0.bin'),
  'wc-turbo-f16': wc('ggml-large-v3-turbo.bin'),
  'parakeet-v3-q8': parakeet,
  'apple-speechanalyzer': apple,
  'groq-large-v3(current)': groq('whisper-large-v3'),
  'groq-large-v3-turbo': groq('whisper-large-v3-turbo'),
  'elevenlabs-scribe-v2': scribe,
}
only = sys.argv[1:] or list(ENGINES)
res = {}
outp = f'{D}/results.jsonl'
for name in only:
    for cond in ['clean', 'noisy', 'cheap']:
        for f in sorted(glob.glob(f'{D}/{cond}/*.wav')):
            cid = os.path.basename(f)[:-4]
            text, wall, rss = ENGINES[name](f, cid[:2])
            rec = dict(engine=name, cond=cond, clip=cid, wall=wall, rss=rss, text=text)
            open(outp, 'a').write(json.dumps(rec, ensure_ascii=False) + '\n')
            print(name, cond, cid, f'{wall:.2f}s', f'{rss:.2f}GB' if rss else '', text[:60], flush=True)
