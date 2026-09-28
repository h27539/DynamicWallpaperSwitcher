#!/usr/bin/env python3
"""Read-only QuickTime/ISO BMFF box inventory; no media decoding or rewriting."""
import argparse
import mmap
import struct
from pathlib import Path

CONTAINERS = {b'moov', b'trak', b'mdia', b'minf', b'stbl', b'edts', b'tapt',
              b'dinf', b'udta', b'meta', b'ilst', b'mvex', b'wave', b'gmhd',
              b'sinf', b'schi', b'moof', b'traf', b'mfra'}
TABLES = {b'stts', b'ctts', b'stss', b'stsc', b'stsz', b'stco', b'co64',
          b'sgpd', b'sbgp', b'cslg', b'csgm', b'elst'}
TARGET_GROUPS = {'tsas', 'stsa', 'tscl', 'tlas', 'rap ', 'sync'}


def u32(buf, pos):
    return struct.unpack_from('>I', buf, pos)[0]


def fourcc(raw):
    return raw.decode('latin-1')


def child_start(buf, box):
    typ = box['type']
    start = box['payload']
    if typ == b'meta':
        return start + 4  # FullBox version/flags
    if typ == b'stsd':
        return start + 8  # FullBox version/flags and entry count
    if typ in {b'hvc1', b'hev1', b'avc1', b'avc3', b'mp4v'}:
        return start + 78  # VisualSampleEntry fixed fields
    return start


def parse_range(buf, start, end, parent='', depth=0):
    pos = start
    while pos + 8 <= end:
        size32 = u32(buf, pos)
        typ = bytes(buf[pos + 4:pos + 8])
        header = 8
        if size32 == 1:
            if pos + 16 > end:
                raise ValueError(f'truncated large box at {pos}')
            size = struct.unpack_from('>Q', buf, pos + 8)[0]
            header = 16
        elif size32 == 0:
            size = end - pos
        else:
            size = size32
        if typ == b'uuid':
            header += 16
        if size < header or pos + size > end:
            raise ValueError(f'invalid {fourcc(typ)} box size={size} offset={pos} parent={parent}')
        path = f'{parent}/{fourcc(typ)}'
        box = {'offset': pos, 'size': size, 'header': header,
               'payload': pos + header, 'end': pos + size, 'type': typ,
               'path': path, 'depth': depth}
        yield box
        if typ in CONTAINERS or typ == b'stsd' or typ in {b'hvc1', b'hev1', b'avc1', b'avc3', b'mp4v'}:
            child = child_start(buf, box)
            if child < box['end']:
                yield from parse_range(buf, child, box['end'], path, depth + 1)
        pos += size
    if pos != end:
        # QuickTime visual sample entries can finish with a four-byte zero pad.
        if parent.endswith(('/hvc1', '/hev1', '/avc1', '/avc3', '/mp4v')) and end-pos <= 4 and not any(buf[pos:end]):
            return
        raise ValueError(f'{end-pos} trailing bytes in {parent} at {pos}')


def details(buf, box):
    typ, p, end = box['type'], box['payload'], box['end']
    n = end - p
    if typ not in TABLES or n < 4:
        return []
    version = buf[p]
    flags = bytes(buf[p + 1:p + 4]).hex()
    out = [f'  version={version} flags=0x{flags}']
    if typ in {b'sgpd', b'sbgp'}:
        if n < 8:
            return out + ['  truncated grouping header']
        group = fourcc(bytes(buf[p + 4:p + 8]))
        out.append(f'  grouping_type={group!r}' + (' [TARGET]' if group in TARGET_GROUPS else ''))
        cur = p + 8
        if typ == b'sgpd':
            if version >= 1:
                if cur + 4 > end: return out + ['  truncated default_length']
                default_length = u32(buf, cur)
                out.append(f'  default_length={default_length}')
                cur += 4
            if version >= 2:
                if cur + 4 > end: return out + ['  truncated default_sample_description_index']
                out.append(f'  default_sample_description_index={u32(buf, cur)}')
                cur += 4
        elif version >= 1:
            if cur + 4 > end: return out + ['  truncated grouping_type_parameter']
            out.append(f'  grouping_type_parameter={u32(buf, cur)}')
            cur += 4
        if cur + 4 > end: return out + ['  truncated entry_count']
        count = u32(buf, cur)
        cur += 4
        out += [f'  entry_count={count}', f'  raw_entries_hex={bytes(buf[cur:end]).hex()}']
        if typ == b'sbgp' and len(buf[cur:end]) == count * 8:
            spans = []
            sample = 1
            for i in range(count):
                run, index = struct.unpack_from('>II', buf, cur + i * 8)
                spans.append(f'{sample}-{sample+run-1}:{index}')
                sample += run
            out.append('  sample_ranges_and_description_indexes=' + ', '.join(spans))
        return out
    if typ in {b'stss', b'stsc', b'stts', b'ctts', b'stco', b'co64', b'elst'} and n >= 8:
        out.append(f'  entry_count={u32(buf, p+4)}')
    if typ == b'stsz' and n >= 12:
        out += [f'  sample_size={u32(buf, p+4)}', f'  sample_count={u32(buf, p+8)}']
    if typ == b'csgm' and n >= 8:
        out.append(f'  grouping_type={fourcc(bytes(buf[p+4:p+8]))!r}')
    if typ in {b'csgm', b'cslg'}:
        out.append(f'  raw_payload_hex={bytes(buf[p:end]).hex()}')
    return out


def inventory(path):
    with path.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as buf:
        boxes = list(parse_range(buf, 0, len(buf)))
        lines = [f'file={path}', f'bytes={len(buf)}', f'box_count={len(boxes)}']
        for b in boxes:
            lines.append(f"{'  '*b['depth']}{b['path']} offset={b['offset']} size={b['size']} header={b['header']}")
            lines.extend(details(buf, b))
        return '\n'.join(lines) + '\n', boxes


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('source', type=Path)
    ap.add_argument('output', type=Path)
    args = ap.parse_args()
    report, _ = inventory(args.source)
    args.output.write_text(report)
    print(f'Wrote {args.output}')
