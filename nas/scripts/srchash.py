"""Independent source hashing on dsserver: reads a tar stream (smbclient -Tc -) of DATASERVER on stdin,
writes '<share>/<path>\t<size>\t<sha256>' per regular file. Usage: smbclient ... -Tc - DIR | srchash.py SHARE OUT.tsv"""
import sys, tarfile, hashlib, os
share, out = sys.argv[1], sys.argv[2]
n = 0
with open(out, "a", encoding="utf-8", errors="surrogateescape") as f:
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|", encoding="utf-8", errors="surrogateescape") as t:
        for m in t:
            if not m.isfile():
                continue
            h = hashlib.sha256(); r = t.extractfile(m); z = 0
            while True:
                blk = r.read(4 << 20)
                if not blk: break
                h.update(blk); z += len(blk)
            name = m.name[2:] if m.name.startswith("./") else m.name.lstrip("/")
            f.write(f"{share}/{name}\t{z}\t{h.hexdigest()}\n"); n += 1
            if n % 500 == 0: f.flush()
print(f"{share}: {n} files hashed", file=sys.stderr)
