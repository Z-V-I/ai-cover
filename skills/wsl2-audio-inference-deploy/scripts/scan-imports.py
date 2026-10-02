#!/usr/bin/env python3
# 扫描推理层源码里所有第三方 import，逐个用 find_spec 检查是否可导入
import ast, os, sys, importlib.util, sysconfig

ROOT = "/opt/svc-inference"
SKIP_DIRS = {".src", "venv", ".python", ".wheels", "__pycache__", ".git", ".workbuddy"}

stdlib = set(sys.stdlib_module_names)

found = {}   # top-level name -> [files]

for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    for fn in filenames:
        if not fn.endswith(".py"):
            continue
        p = os.path.join(dirpath, fn)
        try:
            tree = ast.parse(open(p, encoding="utf-8", errors="ignore").read())
        except Exception:
            continue
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                if node.level and node.level > 0:
                    continue          # 相对导入
                if node.module:
                    names = [node.module]
            for n in names:
                top = n.split(".")[0]
                if not top or top in stdlib:
                    continue
                found.setdefault(top, set()).add(os.path.relpath(p, ROOT))

missing = []
for top in sorted(found):
    try:
        spec = importlib.util.find_spec(top)
    except Exception:
        spec = None
    if spec is None:
        missing.append(top)

print("共发现第三方顶层模块: %d" % len(found))
if missing:
    print("\n!!! 缺失模块 %d 个:" % len(missing))
    for m in missing:
        print("  - %-22s  <- %s" % (m, ", ".join(sorted(found[m])[:3])))
else:
    print("\n全部可导入，无缺失。")

print("\n已可导入的模块:")
for t in sorted(found):
    if t not in missing:
        print("  +", t)
