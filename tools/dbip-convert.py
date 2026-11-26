#!/usr/bin/env python3
"""
relay_tracking: turn DB-IP's free "IP to City Lite" and "IP to ASN Lite" CSVs (https://db-ip.com, CC BY 4.0) into
the compact files the collectors look IPs up in (geoip branch of the plugin repository, see README.md).

    dbip-convert.py city dbip-city-lite-YYYY-MM.csv.gz OUTDIR
    dbip-convert.py asn dbip-asn-lite-YYYY-MM.csv.gz OUTDIR

city: OUTDIR/ranges.tsv      <key of the first address> TAB <location id>, sorted; a range runs until the next key
      OUTDIR/locations.tsv   <location id> TAB <country code> TAB <region> TAB <city>; id 0 = unknown / reserved
asn:  OUTDIR/asn-ranges.tsv  <key of the first address> TAB <AS number>, same layout; 0 = not announced
      OUTDIR/asn-names.tsv   <AS number> TAB <organisation>; 0 = none

key = "4" + 8 hex digits for IPv4, "6" + 32 hex digits for IPv6, so plain string comparison orders addresses (awk
can search the file without any IP library). Only range starts are kept; a gap in the source, and the space after
the last range of IPv4 and of IPv6, get a range of id 0 so they do not inherit the previous one; neighbouring ranges
with the same id are merged; coordinates and continent are dropped.
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


def write_ranges(rows, path):
    """rows: (start, end, id) in address order"""
    last_id, last_end, last_version = None, None, None

    def close(out):
        # space after the last range of an address family: unknown, not the last range's id
        if last_version is not None and last_end < (2 ** 32 if last_version == 4 else 2 ** 128) - 1:
            out.write('%s\t0\n' % key(ipaddress.ip_address(last_end + 1)))

    with open(path, 'w') as out:
        for start, end, rid in rows:
            if last_version is not None and start.version != last_version:
                close(out)
                last_id, last_end, last_version = None, None, None
            contiguous = last_end is not None and int(start) == last_end + 1
            if not (contiguous and rid == last_id):
                if last_end is not None and not contiguous:
                    out.write('%s\t0\n' % key(ipaddress.ip_address(last_end + 1)))
                out.write('%s\t%d\n' % (key(start), rid))
            last_id, last_end, last_version = rid, int(end), start.version
        close(out)


def read(path, width):
    with gzip.open(path, 'rt', encoding='utf-8', newline='') as f:
        for row in csv.reader(f):
            if len(row) >= width:
                yield ipaddress.ip_address(row[0]), ipaddress.ip_address(row[1]), row


def city(path, outdir):
    ids = {('', '', ''): 0}

    def rows():
        for start, end, row in read(path, 6):
            loc = ('', '', '') if row[3] == 'ZZ' else (row[3], clean(row[4]), clean(row[5]))
            yield start, end, ids.setdefault(loc, len(ids))

    write_ranges(rows(), os.path.join(outdir, 'ranges.tsv'))
    with open(os.path.join(outdir, 'locations.tsv'), 'w') as out:
        for loc, lid in sorted(ids.items(), key=lambda x: x[1]):
            out.write('%d\t%s\n' % (lid, '\t'.join(loc)))


def asn(path, outdir):
    names = {}

    def rows():
        for start, end, row in read(path, 4):
            number = int(row[2]) if row[2].isdigit() else 0
            if number:
                names.setdefault(number, clean(row[3]))
            yield start, end, number

    write_ranges(rows(), os.path.join(outdir, 'asn-ranges.tsv'))
    with open(os.path.join(outdir, 'asn-names.tsv'), 'w') as out:
        out.write('0\t\n')
        for number in sorted(names):
            out.write('%d\t%s\n' % (number, names[number]))


if __name__ == '__main__':
    if len(sys.argv) != 4 or sys.argv[1] not in ('city', 'asn'):
        sys.exit('usage: dbip-convert.py city|asn FILE.csv.gz OUTDIR')
    os.makedirs(sys.argv[3], exist_ok=True)
    {'city': city, 'asn': asn}[sys.argv[1]](sys.argv[2], sys.argv[3])
