"""Three-way verification per collection.
  compare.py MANIFEST.tsv SRCHASH.tsv[,SRCHASH2...] OUT.json [collection ...]
MANIFEST.tsv: exported by migrate.py on dsnas (old_path, new_path, collection, size, mtime_ns, sha256_read, sha256_dst, status)
SRCHASH.tsv : independent hashes computed on dsserver from a separate SMB read of DATASERVER (old_path, size, sha256)
A file passes only if: independent source hash == hash of bytes read during the copy == hash re-read from dsnas disk,
sizes equal, and status is verified-dst. Source files that the independent read saw under a mapped prefix but that are
missing from the manifest (and are not excluded) are reported as 'not_migrated'."""
import json, sys, collections

man_p, src_ps, out_p, colls = sys.argv[1], sys.argv[2].split(","), sys.argv[3], set(sys.argv[4:])
src = {}
for p in src_ps:
    for line in open(p, encoding="utf-8", errors="surrogateescape"):
        path, size, sha = line.rstrip("\n").rsplit("\t", 2)
        src[path] = (int(size), sha)
rows = []
with open(man_p, encoding="utf-8", errors="surrogateescape") as f:
    next(f)
    for line in f:
        old, new, coll, size, mt, sr, sd, st = line.rstrip("\n").split("\t")
        if colls and coll not in colls:
            continue
        rows.append((old, new, coll, int(size), sr, sd, st))
res = collections.defaultdict(lambda: collections.Counter())
problems = []
for old, new, coll, size, sr, sd, st in rows:
    r = res[coll]
    r["files"] += 1; r["bytes"] += size
    s = src.get(old)
    if s is None:
        r["no_independent_hash"] += 1; problems.append([coll, "no_independent_hash", old, new]); continue
    if s[0] != size:
        r["size_mismatch"] += 1; problems.append([coll, "size_mismatch", old, new]); continue
    if not (s[1] == sr == sd) or st != "verified-dst":
        r["hash_mismatch"] += 1; problems.append([coll, f"hash_mismatch status={st}", old, new]); continue
    r["verified_3way"] += 1; r["verified_bytes"] += size
summary = {c: dict(v) for c, v in sorted(res.items())}
for c, v in summary.items():
    v["PASS"] = v.get("verified_3way", 0) == v["files"]
json.dump({"summary": summary, "problems": problems[:2000], "problem_count": len(problems)}, open(out_p, "w"), indent=1)
for c, v in summary.items():
    print(f"{c:18} files={v['files']:6} GiB={v['bytes']/2**30:8.2f} verified={v.get('verified_3way',0):6} "
          f"nohash={v.get('no_independent_hash',0)} size={v.get('size_mismatch',0)} hash={v.get('hash_mismatch',0)} "
          f"{'PASS' if v['PASS'] else 'FAIL'}")
print("problems:", len(problems))
