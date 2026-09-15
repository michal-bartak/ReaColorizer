"""Differential fuzz: generate random patterns, record what Python's re does,
and hand them to the Lua engine to compare. Restricted to a syntax subset where
Python and our engine are supposed to agree exactly (ASCII only, so Python's
Unicode-aware \\w does not diverge from our byte-based one)."""
import random, re, json, sys, os

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 12345)

ATOMS = ['a', 'b', 'c', '.', '[ab]', '[^a]', '[a-c]', r'\d', r'\w', r'\s', '_', '1']
QUANT = ['', '', '', '*', '+', '?', '*?', '+?', '??', '{2}', '{1,3}', '{0,2}', '{1,3}?', '{2,}']

def atom(depth):
    r = random.random()
    if depth < 2 and r < 0.22:
        inner = expr(depth + 1)
        return ('(?:' if random.random() < 0.4 else '(') + inner + ')'
    return random.choice(ATOMS)

def piece(depth):
    return atom(depth) + random.choice(QUANT)

def concat(depth):
    return ''.join(piece(depth) for _ in range(random.randint(1, 4)))

def expr(depth):
    n = random.randint(1, 3) if depth < 2 else 1
    return '|'.join(concat(depth) for _ in range(n))

def pattern():
    p = expr(0)
    if random.random() < 0.3: p = '^' + p
    if random.random() < 0.3: p = p + '$'
    return p

ALPHABET = 'aabbc_1 2.'
def subject():
    return ''.join(random.choice(ALPHABET) for _ in range(random.randint(0, 8)))

cases = []
tried = 0
while len(cases) < 4000 and tried < 200000:
    tried += 1
    p = pattern()
    try:
        rx = re.compile(p)
    except re.error:
        continue
    s = subject()
    try:
        m = rx.search(s)
    except Exception:
        continue
    # store 1-based inclusive span to match Lua conventions; None for no match
    if m:
        a, b = m.start() + 1, m.end()     # end is exclusive in py -> inclusive
        cases.append([p, s, a, b])
    else:
        cases.append([p, s, 0, 0])

json.dump(cases, open(os.environ['SP'] + '/fuzz.json', 'w'))
print(f"generated {len(cases)} cases")
