import sys, yaml
path, step, out = sys.argv[1], sys.argv[2], sys.argv[3]
key = sys.argv[4] if len(sys.argv) > 4 else "FINDING_MARKER"
d = yaml.safe_load(open(path, encoding="utf-8"))
for job in d["jobs"].values():
    for s in job.get("steps", []):
        if s.get("name") == step or s.get("id") == step:
            open(out, "w", encoding="utf-8").write(s["run"])
            print(d["env"][key])
            sys.exit(0)
sys.exit("step not found: " + step)
