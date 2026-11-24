#!/usr/bin/env python3
"""
relay_tracking: turn DB-IP's "IP to City Lite" CSV (https://db-ip.com, CC BY 4.0) into the compact files the
collectors look IPs up in (geoip branch of the plugin repository, see README.md).

    dbip-convert.py dbip-city-lite-YYYY-MM.csv.gz OUTDIR

OUTDIR/ranges.tsv     <key of the first address> TAB <location id>, sorted; a range runs until the next line's key
OUTDIR/locations.tsv  <location id> TAB <country code> TAB <region> TAB <city>; id 0 = unknown / reserved

key = "4" + 8 hex digits for IPv4, "6" + 32 hex digits for IPv6, so plain string comparison orders addresses (awk
can search the file without any IP library). DB-IP's ranges cover the whole address space without gaps, so only
starts are kept; neighbouring ranges with the same location are merged; coordinates and continent are dropped.
"""
import csv
import gzip
import ipaddress
import os
import sys


def key(a):
    return ('4%08x' if a.version == 4 else '6%032x') % int(a)


def clean(text):
    return ' '.join(text.replace('\t', ' ').split())


def main(path, outdir):
    os.makedirs(outdir, exist_ok=True)
    ids = {('', '', ''): 0}
    last_id, last_end, last_version = None, None, None
    with gzip.open(path, 'rt', encoding='utf-8', newline='') as f, \
            open(os.path.join(outdir, 'ranges.tsv'), 'w') as out:
        for row in csv.reader(f):
            if len(row) < 6:
                continue
            start, end = ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1])
            loc = ('', '', '') if row[3] == 'ZZ' else (row[3], clean(row[4]), clean(row[5]))
            lid = ids.setdefault(loc, len(ids))
            contiguous = last_version == start.version and last_end is not None and int(start) == last_end + 1
            if not (contiguous and lid == last_id):
                if last_version == start.version and not contiguous:
                    # gap in the source: mark it unknown so it does not inherit the previous location
                    out.write('%s\t0\n' % key(ipaddress.ip_address(last_end + 1)))
                out.write('%s\t%d\n' % (key(start), lid))
            last_id, last_end, last_version = lid, int(end), start.version
    with open(os.path.join(outdir, 'locations.tsv'), 'w') as out:
        for loc, lid in sorted(ids.items(), key=lambda x: x[1]):
            out.write('%d\t%s\n' % (lid, '\t'.join(loc)))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
