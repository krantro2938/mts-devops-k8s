#!/usr/bin/env python3
"""Convert CustomResourceDefinitions (multi-doc YAML on stdin) into JSON schemas
for kubeconform: <outdir>/<kind>_<version>.json (lower-case), group-qualified
like the CRDs-catalog layout: <outdir>/<group>/<kind>_<version>.json.
"""
import json
import os
import sys

import yaml

# Some CRDs contain a bare "=" scalar, which PyYAML maps to the obsolete !!value tag.
yaml.SafeLoader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))

out = sys.argv[1]
n = 0
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get("kind") != "CustomResourceDefinition":
        continue
    spec = doc["spec"]
    group, kind = spec["group"], spec["names"]["kind"].lower()
    for v in spec["versions"]:
        schema = (v.get("schema") or {}).get("openAPIV3Schema")
        if not schema:
            continue
        os.makedirs(os.path.join(out, group), exist_ok=True)
        with open(os.path.join(out, group, f"{kind}_{v['name']}.json"), "w") as f:
            json.dump(schema, f)
        n += 1
print(f"{n} schemas written to {out}", file=sys.stderr)
