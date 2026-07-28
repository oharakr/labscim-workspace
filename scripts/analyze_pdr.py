#!/usr/bin/env python3
"""Build the PDR-vs-N curve from a campaign's .sca files, using the paper's metric.

    PDR = sum(UpstreamPacketLatency.count) / sum(UpstreamPacketGenerated.count)

Latency is only recorded for packets delivered end to end, so its count is the number of
delivered packets, while the generated count is the denominator. Both are summed over the
end-device modules.

The published curve is NOT the plain mean over repetitions. The authors' notebook drops
runs whose generated-packets-per-node falls below 110 -- the nominal value is 120 (one
packet per 60 s over the 7200 s measurement window), so the cut demands at least 92% of
nominal. What it removes are runs where the network never stabilised: in the discarded
N=180 runs the join-state vectors still show churn at t ~ 7800 s, while the kept ones
settled by t ~ 1500 s. At N >= 160 it drops roughly half the runs, which is why the
campaign needs 21 repetitions there to end up with the ~10 the published points rest on.

Reporting both columns is deliberate: the filtered one is comparable to the paper, the
unfiltered one shows how much of the result depends on that choice.

Usage:
    analyze_pdr.py <results-dir> [more-dirs ...] [--prefix TSCHOnly] [--threshold 110]
"""
import argparse
import glob
import os
import re
import statistics
import sys

HOST = re.compile(r'(?:contikinghost|lorahost)\[(\d+)\]')
NPAR = re.compile(r'^(?:par|param|config)\s+\S*num(?:Contiking|LoRa)Hosts\s+(\d+)')


def scan(path):
    """Return (generated, delivered, nodes, hop_sum, hop_weight) for one .sca file.

    Statistic names are matched with and without the "TSCH"/"LoRa" prefix: earlier firmware
    registered them prefixed, current firmware does not, and both appear in archived
    result sets.
    """
    gen = deliv = hop_sum = hop_w = 0.0
    nodes_par = None
    hosts = set()
    cur = hop_count = hop_mean = None

    with open(path, errors='ignore') as f:
        for line in f:
            if line.startswith('statistic '):
                if hop_count and hop_mean is not None:
                    hop_sum += hop_mean * hop_count
                    hop_w += hop_count
                hop_count = hop_mean = cur = None
                parts = line.split()
                if len(parts) < 3 or not HOST.search(parts[1]):
                    continue
                hosts.add(int(HOST.search(parts[1]).group(1)))
                base = parts[2].split(':')[0]
                if base.endswith('UpstreamPacketGenerated'):
                    cur = 'gen'
                elif base.endswith('UpstreamPacketLatency'):
                    cur = 'deliv'
                elif base.endswith('UpstreamPacketHopcount'):
                    cur = 'hop'
            elif line.startswith('field ') and cur:
                p = line.split()
                if len(p) < 3:
                    continue
                if cur == 'hop':
                    if p[1] == 'count':
                        hop_count = float(p[2])
                    elif p[1] == 'mean':
                        hop_mean = float(p[2])
                elif p[1] == 'count':
                    if cur == 'gen':
                        gen += float(p[2])
                    else:
                        deliv += float(p[2])
                    cur = None
            elif nodes_par is None:
                m = NPAR.match(line)
                if m:
                    nodes_par = int(m.group(1))
            if not line.startswith(('field ', 'attr ', 'statistic ')):
                cur = None

    if hop_count and hop_mean is not None:
        hop_sum += hop_mean * hop_count
        hop_w += hop_count
    return gen, deliv, (nodes_par or len(hosts)), hop_sum, hop_w


def runs_for(dirs, prefix, n):
    out = []
    for d in dirs:
        for sca in sorted(glob.glob(f"{d}/{prefix}-run-*-{n}.sca")):
            # A run still in flight has an open, nearly empty .sca; skip it.
            if os.path.getsize(sca) < 100_000:
                continue
            try:
                gen, deliv, nodes, hop_sum, hop_w = scan(sca)
            except OSError as e:
                print(f"  !! {os.path.basename(sca)}: {e}", file=sys.stderr)
                continue
            if gen <= 0 or nodes <= 0:
                continue
            out.append({
                "run": int(re.search(r"run-(\d+)-", sca).group(1)),
                "pdr": deliv / gen,
                "per_node": gen / nodes,
                "hop_sum": hop_sum,
                "hop_w": hop_w,
            })
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", help="directories holding the .sca files")
    ap.add_argument("--prefix", default="TSCHOnly",
                    help="configuration name prefix (TSCHOnly, LoRaOnly, ...)")
    ap.add_argument("--threshold", type=float, default=110.0,
                    help="minimum generated packets per node (0 disables the filter)")
    ap.add_argument("--ns", default="20 40 60 80 100 120 140 160 180 200")
    args = ap.parse_args()

    ns = [int(x) for x in args.ns.split()]
    print(f"{'N':>4} | {'PDR (filtered)':>16} {'kept':>7} | {'PDR (all runs)':>14} "
          f"| {'hops':>5}")
    print("-" * 60)

    for n in ns:
        rows = runs_for(args.dirs, args.prefix, n)
        if not rows:
            continue
        kept = [r for r in rows if r["per_node"] >= args.threshold]
        raw = statistics.fmean([r["pdr"] for r in rows])
        hop_w = sum(r["hop_w"] for r in kept) or sum(r["hop_w"] for r in rows)
        hop_src = kept or rows
        hops = (sum(r["hop_sum"] for r in hop_src) / hop_w) if hop_w else float("nan")
        if kept:
            mu = statistics.fmean([r["pdr"] for r in kept])
            sd = statistics.stdev([r["pdr"] for r in kept]) if len(kept) > 1 else 0.0
            filt = f"{mu:.4f} +-{sd:.4f}"
        else:
            filt = "-- no run kept"
        print(f"{n:>4} | {filt:>16} {len(kept):>3}/{len(rows):<3} | {raw:>14.4f} "
              f"| {hops:>5.2f}")

    print(f"\nfilter: generated packets per node >= {args.threshold:g}"
          f"  (nominal is 120)")


if __name__ == "__main__":
    main()
