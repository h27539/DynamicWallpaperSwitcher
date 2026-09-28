#!/usr/bin/env python3
"""Inspect VCL NAL temporal IDs in an Annex B HEVC elementary stream."""
import csv
import sys
from collections import Counter
from pathlib import Path


def units(data: bytes):
    starts = []
    i = 0
    while i < len(data) - 3:
        if data[i:i + 3] == b"\0\0\1":
            starts.append((i, 3))
            i += 3
        elif data[i:i + 4] == b"\0\0\0\1":
            starts.append((i, 4))
            i += 4
        else:
            i += 1
    for n, (offset, prefix) in enumerate(starts):
        end = starts[n + 1][0] if n + 1 < len(starts) else len(data)
        nal = data[offset + prefix:end]
        if len(nal) >= 3:
            yield nal


source = Path(sys.argv[1])
target = Path(sys.argv[2])
rows = []
for nal in units(source.read_bytes()):
    nal_type = (nal[0] >> 1) & 0x3f
    if nal_type > 31:
        continue
    rows.append((len(rows) + 1, nal_type, (nal[1] & 7) - 1,
                 bool(nal[2] & 0x80), len(nal)))
with target.open("w", newline="") as handle:
    writer = csv.writer(handle)
    writer.writerow(("sampleIndex", "nalType", "temporalID", "firstSlice", "nalBytes"))
    writer.writerows(rows)
print(f"VCL samples={len(rows)} temporal IDs={dict(sorted(Counter(x[2] for x in rows).items()))}")
print(f"first-slice flags={dict(sorted(Counter(x[3] for x in rows).items()))}")
