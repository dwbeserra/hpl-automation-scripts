#!/usr/bin/env python3
import argparse
import csv
import glob
import os
import re
import sys


def extract_gflops(path):
    last_wr = None
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.lstrip().startswith("WR"):
                    last_wr = line.strip()
    except OSError:
        return None

    if not last_wr:
        return None

    parts = last_wr.split()
    if not parts:
        return None

    try:
        return float(parts[-1])
    except ValueError:
        return None


def main():
    parser = argparse.ArgumentParser(
        description="Find the N with the highest mean GFLOPS among complete hpl_n_varies results."
    )
    parser.add_argument("--root", default=".", help="Directory containing N* result folders.")
    parser.add_argument("--repetitions", type=int, required=True, help="Expected number of repetitions.")
    parser.add_argument("--summary", default="n_performance_summary.csv", help="CSV summary output.")
    parser.add_argument("--env", default="best_n.env", help="Shell env output with BEST_N.")
    args = parser.parse_args()

    expected_reps = set(range(args.repetitions))
    rows = []
    best = None

    pattern = re.compile(r"^N(\d+)$")

    for name in sorted(os.listdir(args.root)):
        full = os.path.join(args.root, name)
        if not os.path.isdir(full):
            continue

        m = pattern.match(name)
        if not m:
            continue

        n_value = int(m.group(1))
        rep_values = {}
        for out_path in glob.glob(os.path.join(full, f"HPL_{n_value}_rep*.out")):
            bm = re.search(r"_rep(\d+)\.out$", os.path.basename(out_path))
            if not bm:
                continue

            rep = int(bm.group(1))
            if rep not in expected_reps:
                continue

            g = extract_gflops(out_path)
            if g is not None:
                rep_values[rep] = g

        missing = sorted(expected_reps - set(rep_values.keys()))
        complete = len(missing) == 0
        mean_gflops = sum(rep_values.values()) / len(rep_values) if rep_values else float("nan")

        row = {
            "N": n_value,
            "Complete": "yes" if complete else "no",
            "Valid_repetitions": len(rep_values),
            "Expected_repetitions": args.repetitions,
            "Missing_repetitions": " ".join(map(str, missing)),
            "Mean_GFLOPS": mean_gflops,
        }
        rows.append(row)

        if complete:
            if best is None or mean_gflops > best["Mean_GFLOPS"]:
                best = row

    with open(args.summary, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "N", "Complete", "Valid_repetitions", "Expected_repetitions",
                "Missing_repetitions", "Mean_GFLOPS"
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    if best is None:
        print("No complete N result found.", file=sys.stderr)
        print(f"Summary written to: {args.summary}", file=sys.stderr)
        sys.exit(1)

    with open(args.env, "w", encoding="utf-8") as f:
        f.write(f"BEST_N={best['N']}\n")
        f.write(f"BEST_N_MEAN_GFLOPS={best['Mean_GFLOPS']}\n")

    print(f"Best complete N: {best['N']}")
    print(f"Mean GFLOPS: {best['Mean_GFLOPS']}")
    print(f"Summary written to: {args.summary}")
    print(f"Env file written to: {args.env}")


if __name__ == "__main__":
    main()
