#!/usr/bin/env python3
"""Turns native-image query code (-H:+ExitAfterQueryCodeGeneration) into CAP cache files
without running it on the target: every printf becomes a call to an external function,
clang -O2 folds the arguments to constants, and the values are read back from the LLVM IR.

usage: capgen.py <clang> <querydir> <outdir> [clang args...]
"""
import os
import re
import subprocess
import sys

clang, qdir, outdir = sys.argv[1:4]
cflags = sys.argv[4:]
os.makedirs(outdir, exist_ok=True)

PRELUDE = '#include <stdio.h>\nvoid capgen_rec(int id, const char *fmt, ...);\n#define printf(...) capgen_rec(__COUNTER__, __VA_ARGS__)\n'
CALL = re.compile(r'call void \(i32, ptr, \.\.\.\) @capgen_rec\(i32 (?:noundef )?(\d+), ptr (?:noundef )?(?:nonnull )?(@[\w.]+)(.*?)\)(?: #\d+)?$', re.M)
STR = re.compile(r'^(@[\w.]+) = .*?c"((?:[^"\\]|\\.)*)"', re.M)
FMT = re.compile(r'%(l?[uXsd])')


def cstr(s):
    out = bytearray()
    i = 0
    while i < len(s):
        if s[i] == '\\':
            out.append(int(s[i + 1:i + 3], 16))
            i += 3
        else:
            out.append(ord(s[i]))
            i += 1
    return out.rstrip(b'\0').decode()


failed = []
for name in sorted(os.listdir(qdir)):
    if not name.endswith('.c'):
        continue
    src = open(os.path.join(qdir, name)).read()
    # the prelude must come after the query's own includes and defines
    idx = src.find('\nint ')
    head, body = src[:idx], src[idx:]
    mod = head + '\n' + PRELUDE + body
    tmp_c = os.path.join(outdir, name + '.mod.c')
    tmp_ll = os.path.join(outdir, name + '.ll')
    open(tmp_c, 'w').write(mod)
    r = subprocess.run([clang, '-O2', '-S', '-emit-llvm', '-o', tmp_ll, tmp_c] + cflags, capture_output=True, text=True)
    if r.returncode != 0:
        failed.append(name)
        sys.stderr.write('== %s failed\n%s\n' % (name, r.stderr[-3000:]))
        continue
    ir = open(tmp_ll).read()
    strings = {m.group(1): cstr(m.group(2)) for m in STR.finditer(ir)}
    lines = {}
    for m in CALL.finditer(ir):
        idx, fmtref, rest = int(m.group(1)), m.group(2), m.group(3)
        fmt = strings[fmtref]
        args = [a.strip() for a in rest.split(',') if a.strip()]
        vals = []
        for spec, arg in zip(FMT.findall(fmt), args):
            parts = arg.split()
            v = parts[-1]
            if spec == 's':
                vals.append(strings[v])
            elif v.startswith('@') or not re.fullmatch(r'-?\d+', v):
                raise SystemExit('%s: non-constant argument %r in %r' % (name, arg, fmt))
            else:
                n = int(v)
                bits = 64 if parts[0] == 'i64' else 32
                vals.append(n & ((1 << bits) - 1))
        py = FMT.sub(lambda s: {'lu': '%d', 'lX': '%X', 's': '%s', 'd': '%d', 'u': '%d', 'X': '%X'}[s.group(1)], fmt)
        lines[idx] = py % tuple(vals)
    open(os.path.join(outdir, name[:-2] + '.cap'), 'w').write(''.join(lines[k] for k in sorted(lines)))
    print('%s: %d values (printf calls in source: %d)' % (name, len(lines), len(re.findall(r'^\s*printf\(', body, re.M))))
if failed:
    sys.exit('FAILED: %s' % failed)
