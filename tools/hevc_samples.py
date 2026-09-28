#!/usr/bin/env python3
"""Read first HEVC samples through original stsc/stco/stsz; inspect NAL headers only."""
import mmap
import struct
import sys
from collections import Counter
from pathlib import Path
from bmff_boxes import parse_range

ROOT = Path(__file__).resolve().parent
SOURCE = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'GG-original.mov'
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / 'gg-hevc-nal-headers.txt'
CSV = Path(sys.argv[3]) if len(sys.argv) > 3 else ROOT / 'gg-hevc-temporal-ids.csv'


def u32(buf, at): return struct.unpack_from('>I', buf, at)[0]


with SOURCE.open('rb') as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as buf:
    boxes = list(parse_range(buf, 0, len(buf)))
    one = lambda typ: next(b for b in boxes if b['type'] == typ)
    stsc, stco, stsz, hvcc = (one(t) for t in (b'stsc', b'stco', b'stsz', b'hvcC'))
    stsc_entries = [struct.unpack_from('>III', buf, stsc['payload'] + 8 + i*12)
                    for i in range(u32(buf, stsc['payload'] + 4))]
    chunk_offsets = [u32(buf, stco['payload'] + 8 + i*4)
                     for i in range(u32(buf, stco['payload'] + 4))]
    sample_sizes = [u32(buf, stsz['payload'] + 12 + i*4)
                    for i in range(u32(buf, stsz['payload'] + 8))]
    length_size = (buf[hvcc['payload'] + 21] & 3) + 1
    lines = [f'file={SOURCE}', f'sample_count={len(sample_sizes)}',
             f'chunk_count={len(chunk_offsets)}', f'nal_length_field_bytes={length_size}']
    sample = 0
    temporal_counts = Counter()
    nal_type_counts = Counter()
    key_samples = []
    nal_rows = ['sample,temporal_id,first_nal_type']
    for chunk_index, offset in enumerate(chunk_offsets, 1):
        setting = max(x for x in stsc_entries if x[0] <= chunk_index)
        samples_per_chunk = setting[1]
        at = offset
        for _ in range(samples_per_chunk):
            if sample >= len(sample_sizes): break
            size = sample_sizes[sample]
            if True:
                cursor = at
                nal = []
                while cursor < at + size:
                    length = int.from_bytes(buf[cursor:cursor+length_size], 'big')
                    cursor += length_size
                    if length < 2 or cursor + length > at + size:
                        raise ValueError(f'Bad NAL length sample={sample+1} at={cursor}')
                    h0, h1 = buf[cursor], buf[cursor+1]
                    nal_type = (h0 >> 1) & 0x3f
                    layer_id = ((h0 & 1) << 5) | (h1 >> 3)
                    temporal_id = (h1 & 7) - 1
                    if not nal:
                        temporal_counts[temporal_id] += 1
                        nal_type_counts[nal_type] += 1
                        if nal_type in (16, 17, 18, 19, 20, 21): key_samples.append(sample+1)
                        nal_rows.append(f'{sample+1},{temporal_id},{nal_type}')
                    if sample < 64:
                        nal.append(f'type={nal_type}/layer={layer_id}/temporal_id={temporal_id}')
                    else:
                        nal.append('seen')
                    cursor += length
                if sample < 64:
                    lines.append(f'sample={sample+1} file_offset={at} bytes={size} NALs={";".join(nal)}')
            at += size
            sample += 1
    lines[4:4] = [f'temporal_id_counts={dict(sorted(temporal_counts.items()))}',
                  f'first_nal_type_counts={dict(sorted(nal_type_counts.items()))}',
                  f'key_sample_count={len(key_samples)} first_key_samples={key_samples[:30]}',
                  f'key_sample_interval_counts={dict(sorted(Counter(b-a for a,b in zip(key_samples,key_samples[1:])).items()))}']
    OUT.write_text('\n'.join(lines) + '\n')
    CSV.write_text('\n'.join(nal_rows) + '\n')
    print(f'Wrote {OUT}')
