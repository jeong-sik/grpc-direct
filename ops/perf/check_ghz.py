#!/usr/bin/env python3
import argparse
import re
import sys

THRESHOLDS = {
    "standard": {
        "rps_min": 31180.00,
        "p95_max": 1.99,
        "p99_max": 2.23,
        "error_rate_max": 0.1,
    },
    "high": {
        "rps_min": 35013.13,
        "p95_max": 6.65,
        "p99_max": 6.86,
        "error_rate_max": 0.1,
    },
}


def parse_ghz(text):
    result = {}

    m = re.search(r"Requests/sec:\s*([0-9.]+)", text)
    if m:
        result["rps"] = float(m.group(1))

    m = re.search(r"Count:\s*([0-9]+)", text)
    if m:
        result["count"] = int(m.group(1))

    for match in re.finditer(r"\b(50|95|99)\s*%\s*in\s*([0-9.]+)\s*ms", text):
        pct = int(match.group(1))
        result[f"p{pct}"] = float(match.group(2))

    statuses = re.findall(r"\[([A-Za-z0-9_]+)\]\s+([0-9]+)", text)
    if statuses and "count" in result:
        total = result["count"]
        ok = 0
        for code, num in statuses:
            if code == "OK":
                ok += int(num)
        error_count = max(0, total - ok)
        result["error_rate"] = (error_count / total) * 100.0 if total > 0 else 0.0
    else:
        result["error_rate"] = 0.0

    return result


def check(values, thresholds):
    errors = []
    rps = values.get("rps")
    p95 = values.get("p95")
    p99 = values.get("p99")
    error_rate = values.get("error_rate", 0.0)

    if rps is None:
        errors.append("Missing RPS")
    elif rps < thresholds["rps_min"]:
        errors.append(f"RPS {rps:.2f} < {thresholds['rps_min']:.2f}")

    if p95 is None:
        errors.append("Missing P95")
    elif p95 > thresholds["p95_max"]:
        errors.append(f"P95 {p95:.2f} > {thresholds['p95_max']:.2f}")

    if p99 is None:
        errors.append("Missing P99")
    elif p99 > thresholds["p99_max"]:
        errors.append(f"P99 {p99:.2f} > {thresholds['p99_max']:.2f}")

    if error_rate > thresholds["error_rate_max"]:
        errors.append(f"Error rate {error_rate:.3f}% > {thresholds['error_rate_max']:.3f}%")

    return errors


def main():
    parser = argparse.ArgumentParser(description="Validate ghz output against perf thresholds")
    parser.add_argument("--mode", choices=THRESHOLDS.keys(), required=True)
    parser.add_argument("--file", required=True)
    args = parser.parse_args()

    try:
        with open(args.file, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as exc:
        print(f"Failed to read {args.file}: {exc}", file=sys.stderr)
        return 1

    values = parse_ghz(text)
    errors = check(values, THRESHOLDS[args.mode])

    rps = values.get("rps")
    p50 = values.get("p50")
    p95 = values.get("p95")
    p99 = values.get("p99")
    error_rate = values.get("error_rate", 0.0)

    print(f"mode={args.mode} rps={rps} p50={p50} p95={p95} p99={p99} error_rate={error_rate:.3f}%")

    if errors:
        print("FAIL")
        for err in errors:
            print(f"- {err}")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
