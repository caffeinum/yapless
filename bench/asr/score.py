import json, sys, os, statistics as st
from collections import defaultdict
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
from whisper_normalizer.basic import BasicTextNormalizer
D = os.path.dirname(os.path.abspath(__file__))
en, basic = EnglishTextNormalizer(), BasicTextNormalizer()
refs = {f[:-4]: open(f'{D}/ref/{f}').read() for f in os.listdir(f'{D}/ref')}
rows = [json.loads(l) for l in open(f'{D}/results.jsonl')]
agg = defaultdict(lambda: defaultdict(list)); walls = defaultdict(list); rss = defaultdict(list)
for r in rows:
    lang = r['clip'][:2]; norm = en if lang == 'en' else basic
    ref, hyp = norm(refs[r['clip']]), norm(r['text'])
    w = jiwer.wer(ref, hyp) if hyp.strip() else 1.0
    key = r['cond'] if lang == 'en' else 'ru-' + r['cond']
    agg[r['engine']][key].append((len(ref.split()), w))
    walls[r['engine']].append(r['wall'])
    if r['rss']: rss[r['engine']].append(r['rss'])
def pooled(v): return 100 * sum(n*w for n, w in v) / sum(n for n, _ in v)
cols = ['clean', 'noisy', 'cheap', 'ru-clean', 'ru-noisy', 'ru-cheap']
print(f"{'engine':24}" + ''.join(f'{c:>9}' for c in cols) + '   wall-med  maxRSS')
for e in agg:
    print(f'{e:24}' + ''.join(f'{pooled(agg[e][c]):9.1f}' for c in cols) + f'   {st.median(walls[e]):6.2f}s  ' + (f'{max(rss[e]):.2f}GB' if rss[e] else '  cloud'))
if len(sys.argv) > 1:
    for r in rows:
        if r['engine'] == sys.argv[1]: print(r['cond'], r['clip'], '|', r['text'])
