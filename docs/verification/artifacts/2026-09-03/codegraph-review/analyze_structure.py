# -*- coding: utf-8 -*-
"""Codegraph-based structure review for StarChat / ChatFlow.

Data sources:
  1. .codegraph/codegraph.db  (codegraph CLI v1.6.0 index, refreshed via `codegraph sync`)
  2. Filesystem walk + `git ls-files`
Outputs: codegraph-analysis.json + stdout summary.
"""
import json
import os
import posixpath
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from collections import Counter, defaultdict
from pathlib import Path, PurePosixPath

ROOT = Path(r"D:\pythonProject\outsource\StarChat")
OUT_DIR = ROOT / "docs" / "verification" / "artifacts" / "2026-09-03" / "codegraph-review"
OUT_DIR.mkdir(parents=True, exist_ok=True)

EXCLUDE_WALK = {
    ".git", ".worktrees", "node_modules", ".venv", "__pycache__", ".dart_tool",
    ".gradle", ".idea", ".vscode", ".pytest_cache", ".ruff_cache", ".mypy_cache",
    "coverage", "ephemeral", ".symlinks", "Pods", ".codegraph", ".zcode",
    ".claude", ".superpowers", ".agents", "data",
}

CODE_AREAS = ("backend", "services", "apps", "frontend", "design-demo", "tests", "scripts", "packages", "infra")

ASSET_EXTS = {
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".bmp",
    ".css", ".js", ".mjs",
    ".ttf", ".otf", ".woff", ".woff2",
    ".mp3", ".wav", ".aac", ".ogg", ".flac",
    ".mp4", ".webm", ".mov",
}

# ---------------------------------------------------------------- filesystem

def git_tracked():
    out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True)
    return {p.decode("utf-8") for p in out.stdout.split(b"\x00") if p}

def walk_files():
    rows = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        # keep the git-tracked root build/ but prune every nested local build tree
        dirnames[:] = [d for d in dirnames
                       if d not in EXCLUDE_WALK
                       and d != ".cxx"
                       and not (d == "build" and Path(dirpath) != ROOT)]
        for f in filenames:
            p = Path(dirpath) / f
            rel = p.relative_to(ROOT).as_posix()
            try:
                size = p.stat().st_size
            except OSError:
                size = 0
            rows.append({"rel": rel, "size": size, "ext": p.suffix.lower()})
    return rows

files = walk_files()
tracked = git_tracked()
for r in files:
    r["tracked"] = r["rel"] in tracked

# ---------------------------------------------------------------- codegraph db

def open_codegraph():
    tmp = tempfile.mkdtemp(prefix="cgdb_")
    for ext in ("", "-wal", "-shm"):
        src = ROOT / ".codegraph" / ("codegraph.db" + ext)
        if src.exists():
            shutil.copy2(src, Path(tmp) / ("codegraph.db" + ext))
    con = sqlite3.connect(str(Path(tmp) / "codegraph.db"))
    return con

cg = open_codegraph()
cur = cg.cursor()

# file -> file import edges from the codegraph index
file_nodes = {rid: pth for rid, pth in cur.execute("SELECT id, file_path FROM nodes WHERE kind='file'")}
import_edges = []
for s, t in cur.execute(
        "SELECT e.source, e.target FROM edges e "
        "JOIN nodes ns ON ns.id = e.source JOIN nodes nt ON nt.id = e.target "
        "WHERE e.kind='imports' AND ns.kind='file' AND nt.kind='file'"):
    ps, pt = file_nodes.get(s), file_nodes.get(t)
    if ps and pt and ps != pt:
        import_edges.append((ps.replace("\\", "/"), pt.replace("\\", "/")))

# files table stats
cg_files = list(cur.execute("SELECT path, language, generated FROM files"))
generated_files = [p for p, _l, g in cg_files if g]

def tarjan_scc(graph):
    sys.setrecursionlimit(100000)
    index, low, on_stack, stack, counter, out = {}, {}, set(), [], [0], []

    def strong(v):
        index[v] = low[v] = counter[0]; counter[0] += 1
        stack.append(v); on_stack.add(v)
        for w in graph.get(v, ()):
            if w not in index:
                strong(w)
                low[v] = min(low[v], low[w])
            elif w in on_stack:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            comp = []
            while True:
                w = stack.pop(); on_stack.discard(w); comp.append(w)
                if w == v:
                    break
            out.append(comp)

    for v in graph:
        if v not in index:
            strong(v)
    return out

graph = defaultdict(set)
for s, t in import_edges:
    graph[s].add(t)

sccs = [c for c in tarjan_scc(graph) if len(c) > 1]
sccs.sort(key=lambda c: -len(c))

fanin = Counter()
for _s, t in import_edges:
    fanin[t] += 1

cross_area = []
for s, t in import_edges:
    if s.split("/", 1)[0] != t.split("/", 1)[0]:
        cross_area.append((s, t))

# ---------------------------------------------------------------- duplicates

def area_of(rel):
    top = rel.split("/", 1)[0]
    if top == "apps" and rel.count("/") >= 1:
        return "/".join(rel.split("/")[:2])
    return top

by_area_basename = defaultdict(lambda: defaultdict(list))
dir_names = defaultdict(list)
for r in files:
    a = area_of(r["rel"])
    base = PurePosixPath(r["rel"]).name
    if r["ext"] in (".py", ".dart", ".ts", ".tsx", ".js", ".jsx", ".kt", ".swift"):
        by_area_basename[a][base].append(r["rel"])
    parent = posixpath.dirname(r["rel"])
    if parent:
        dir_names[(parent, posixpath.basename(parent))].append(r["rel"])

dup_groups = {}
for a, m in by_area_basename.items():
    groups = {b: ps for b, ps in m.items() if len(ps) > 1}
    if groups:
        dup_groups[a] = groups

# duplicate directory names (same dir basename reused in >=2 places)
dup_dir_names = defaultdict(list)
for (parent, name), rels in dir_names.items():
    dup_dir_names[name].append(parent)
dup_dir_names = {n: sorted(ps) for n, ps in dup_dir_names.items() if len(ps) >= 2 and len(n) > 2}

# ---------------------------------------------------------------- naming checks

bad_name_py_dart = []
for r in files:
    if r["ext"] in (".py", ".dart") and not re.fullmatch(r"[a-z0-9_]+", PurePosixPath(r["rel"]).stem):
        bad_name_py_dart.append(r["rel"])

bad_dirs = []
for dirpath, dirnames, _f in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in EXCLUDE_WALK]
    for d in dirnames:
        rel = (Path(dirpath) / d).relative_to(ROOT).as_posix()
        if area_of(rel) in CODE_AREAS and not re.fullmatch(r"[a-z0-9_.\-]+", d):
            bad_dirs.append(rel)

# ---------------------------------------------------------------- static assets

def classify_asset(rel):
    p = rel
    if p.startswith("apps/mobile_flutter/assets/"):
        return "mobile-assets(OK)"
    if p.startswith(("apps/mobile_flutter/android/", "apps/mobile_flutter/ios/", "apps/mobile_flutter/web/")):
        return "platform-resources(OK)"
    if p.startswith("frontend/public/"):
        return "web-public(OK)"
    if p.startswith("frontend/"):
        return "frontend-other"
    if p.startswith("design-demo/assets/"):
        return "demo-assets(OK)"
    if p.startswith("design-demo/"):
        return "demo-other"
    if p.startswith("docs/"):
        return "docs-evidence(OK)"
    if p.startswith("tests/") and "/fixtures/" in p:
        return "test-fixtures(OK)"
    if p.startswith("infra/"):
        return "infra-vendored(OK)"
    if p.startswith("build/"):
        return "build-output(FLAG)"
    if p.startswith(("backend/", "services/", "scripts/", "packages/")):
        return "backend-area(FLAG)"
    return "root-or-other(FLAG)"

assets = [r for r in files if r["ext"] in ASSET_EXTS]
asset_classes = Counter()
asset_flagged = defaultdict(list)
for r in assets:
    c = classify_asset(r["rel"])
    asset_classes[c] += 1
    if c.endswith("(FLAG)"):
        asset_flagged[c].append(r["rel"])
    if r["ext"] == ".js":
        # JS is both asset and code; only treat as asset when outside src/lib dirs
        pass

# ---------------------------------------------------------------- tests

def is_py_test(rel):
    return PurePosixPath(rel).name.startswith("test_") and PurePosixPath(rel).name.endswith(".py")

def is_dart_test(rel):
    return rel.endswith("_test.dart")

def is_js_test(rel):
    return re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", rel) is not None

test_files = [r["rel"] for r in files if is_py_test(r["rel"]) or is_dart_test(r["rel"]) or is_js_test(r["rel"])]

misplaced_tests = [r for r in test_files
                   if (r.startswith(("backend/app", "services/")) and is_py_test(r))
                   or (r.startswith("apps/mobile_flutter/lib/") and is_dart_test(r))
                   or ((r.startswith("frontend/src/") or r.startswith("design-demo/src/")) and is_js_test(r))]

src_root = ROOT / "services" / "business-api" / "app"

def py_test_match(rel):
    """Map tests/business_api/<sub>/test_<name>.py onto backend app sources."""
    rest = rel[len("tests/business_api/"):]
    sub, fname = posixpath.split(rest)
    name = fname[len("test_"):-len(".py")]
    toks = [t for t in name.split("_") if t]
    hits = []
    for order in (toks, toks[::-1], toks[1:] if len(toks) > 1 else toks):
        cand = "_".join(order)
        for base in ("api", "modules", "core", "integrations", "cli"):
            if (src_root / base).with_suffix(".py").exists():
                hits.append(f"app/{base}.py")
            d = src_root / base / cand
            if d.with_suffix(".py").exists():
                hits.append(f"app/{base}/{cand}.py")
            if (src_root / base / cand).is_dir():
                hits.append(f"app/{base}/{cand}/")
        if hits:
            break
    if sub:
        for base in ("api", "modules", "core", "integrations"):
            if (src_root / base / sub).is_dir():
                hits.append(f"app/{base}/{sub}/")
    return sorted(set(hits))

unmatched_py_tests = []
for r in sorted(test_files):
    if r.startswith("tests/business_api/") and is_py_test(r):
        if not py_test_match(r):
            unmatched_py_tests.append(r)

# flutter mirror
lib_root = ROOT / "apps" / "mobile_flutter" / "lib"
test_root = ROOT / "apps" / "mobile_flutter" / "test"
flutter_pairs = {"matched": 0, "unmatched": []}
if test_root.exists():
    for p in test_root.rglob("*_test.dart"):
        rel = p.relative_to(test_root).as_posix()
        src = rel[: -len("_test.dart")] + ".dart"
        if (lib_root / src).exists():
            flutter_pairs["matched"] += 1
        else:
            flutter_pairs["unmatched"].append(f"test/{rel}")

lib_untested = defaultdict(int)
lib_total = defaultdict(int)
GEN_DART = (".g.dart", ".freezed.dart")
if lib_root.exists():
    for p in lib_root.rglob("*.dart"):
        if p.name.endswith(GEN_DART):
            continue
        rel = p.relative_to(lib_root).as_posix()
        key = "/".join(rel.split("/")[:2]) if "/" in rel else "(lib root)"
        lib_total[key] += 1
        t = test_root / (rel[: -len(".dart")] + "_test.dart")
        if not t.exists():
            lib_untested[key] += 1

# ---------------------------------------------------------------- dir inventory

dir_inv = {}
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in EXCLUDE_WALK]
    rel = Path(dirpath).relative_to(ROOT).as_posix()
    depth = rel.count("/") + 1 if rel != "." else 0
    if depth == 0 or depth > 3:
        continue
    exts = Counter(Path(f).suffix.lower() or "(none)" for f in filenames)
    tr = sum(1 for f in filenames if (Path(dirpath) / f).relative_to(ROOT).as_posix() in tracked)
    size = sum((Path(dirpath) / f).stat().st_size for f in filenames
               if (Path(dirpath) / f).is_file())
    dir_inv[rel] = {
        "files": len(filenames), "tracked": tr, "size_kb": round(size / 1024),
        "top_exts": exts.most_common(4),
    }

root_files = [r for r in files if "/" not in r["rel"]]

# ---------------------------------------------------------------- pubspec assets

pubspec_assets = []
pubspec = ROOT / "apps" / "mobile_flutter" / "pubspec.yaml"
if pubspec.exists():
    in_assets = False
    for line in pubspec.read_text(encoding="utf-8", errors="replace").splitlines():
        if re.match(r"^\s*assets:\s*$", line):
            in_assets = True
            continue
        if in_assets:
            m = re.match(r"^\s*-\s*(\S+)", line)
            if m:
                pubspec_assets.append(m.group(1))
            elif line.strip() and not line.startswith(" "):
                in_assets = False

# ---------------------------------------------------------------- emit

result = {
    "codegraph": {
        "db_files": len(cg_files),
        "generated_indexed": len(generated_files),
        "file_import_edges": len(import_edges),
        "scc_count": len(sccs),
        "sccs": [sorted(c) for c in sccs[:20]],
        "cross_area_imports": cross_area[:40],
        "top_fanin": fanin.most_common(15),
    },
    "counts": {
        "walked_files": len(files),
        "tracked": len(tracked),
        "assets": len(assets),
        "test_files": len(test_files),
    },
    "dup_basename_groups": {a: {b: ps for b, ps in g.items()} for a, g in dup_groups.items()},
    "dup_dir_names": dict(sorted(dup_dir_names.items())),
    "bad_py_dart_names": bad_name_py_dart,
    "bad_dirs": bad_dirs,
    "asset_classes": dict(asset_classes),
    "asset_flagged": {k: sorted(v)[:60] for k, v in asset_flagged.items()},
    "asset_locations": Counter(posixpath.dirname(r["rel"]) for r in assets).most_common(40),
    "tests": {
        "all": sorted(test_files),
        "misplaced": misplaced_tests,
        "py_unmatched": unmatched_py_tests,
        "flutter": {**flutter_pairs, "unmatched": flutter_pairs["unmatched"][:30]},
        "lib_untested": dict(lib_untested),
        "lib_total": dict(lib_total),
    },
    "dir_inventory": dir_inv,
    "root_files": sorted(r["rel"] for r in root_files),
    "pubspec_assets": pubspec_assets,
}

(OUT_DIR / "codegraph-analysis.json").write_text(
    json.dumps(result, ensure_ascii=False, indent=1, default=str), encoding="utf-8")

# ---------------- console summary ----------------
P = print
P("== codegraph ==")
P("indexed files:", len(cg_files), "| generated:", len(generated_files))
P("file->file import edges:", len(import_edges))
P("SCCs (cycles):", len(sccs))
for c in sccs[:10]:
    P("  cycle size", len(c), "->", "; ".join(sorted(c)[:6]), "..." if len(c) > 6 else "")
P("cross-area imports:", len(cross_area))
for s, t in cross_area[:15]:
    P("   ", s, "->", t)
P("top fan-in:", fanin.most_common(10))
P()
P("== duplicate basenames ==")
for a, g in sorted(dup_groups.items()):
    big = {b: ps for b, ps in g.items() if b not in ("__init__.py",)}
    P(a, "->", len(g), "dup names;", len(big), "excl __init__")
    for b, ps in list(big.items())[:8]:
        P("   ", b, "x", len(ps))
P()
P("== dup dir names (>=2 places) ==")
for n, ps in sorted(dup_dir_names.items()):
    P(f"{n}: {len(ps)} ->", "; ".join(ps[:6]))
P()
P("== bad py/dart file names ==", bad_name_py_dart[:15])
P("== bad dir names ==", bad_dirs[:15])
P()
P("== asset classes ==")
for k, v in asset_classes.most_common():
    P(f"  {k}: {v}")
P("== flagged asset samples ==")
for k, v in asset_flagged.items():
    P(" ", k, len(v))
    for x in sorted(v)[:12]:
        P("    ", x)
P()
P("== asset locations (top) ==")
for d, c in result["asset_locations"][:25]:
    P(f"  {c:4d}  {d}")
P()
P("== tests ==", len(test_files), "files; misplaced:", misplaced_tests)
P("flutter mirror matched:", flutter_pairs["matched"], "unmatched:", len(flutter_pairs["unmatched"]))
for x in flutter_pairs["unmatched"][:12]:
    P("   ", x)
P("py tests w/o source match:", len(unmatched_py_tests))
for x in unmatched_py_tests[:15]:
    P("   ", x)
P("lib files w/o test (by dir):")
for k, v in sorted(lib_untested.items()):
    P(f"   {k}: {v}/{lib_total[k]}")
P()
P("== root files ==")
for r in result["root_files"]:
    tr = "T" if r in tracked else "-"
    P(f"  [{tr}] {r}")
P()
P("== pubspec assets ==")
P(pubspec_assets)
