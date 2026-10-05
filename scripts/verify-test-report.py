#!/usr/bin/env python3
"""Gate a `swift test --xunit-output` report. Exit 0 is the only pass.

  Mint the declared list from a RED run (the tests that failed):
    verify-test-report.py --report red.xml --emit-declared declared.json

  Check a later run against it:
    verify-test-report.py --report green.xml --declared declared.json \
        --expect passing --since 2026-10-02T20:00:00Z

Exit codes: 0 pass, 1 gate failure, 2 usage error.

The declared list is derived from a report, never written by hand, so it cannot under-declare;
re-asserting it at every later run is what turns a deleted test into a failure. SwiftPM's report
records a skipped XCTest as passed, so a skip is refused at the source instead: any `XCTSkip` under
--tests fails the gate. A RED failure's REASON is not checked (SwiftPM writes only "failure"): read
the failure messages before minting.
"""

import argparse
import datetime
import json
import os
import sys
import xml.etree.ElementTree as ET


def fail(message, code=1):
    print(f"[FAIL] {message}", file=sys.stderr)
    sys.exit(code)


def read_report(path):
    roots = []
    # `swift test` writes Swift Testing results to a sibling file; a failure there must count too.
    stem, extension = os.path.splitext(path)
    for candidate in (path, f"{stem}-swift-testing{extension}"):
        if candidate != path and not os.path.exists(candidate):
            continue
        try:
            roots.append(ET.parse(candidate).getroot())
        except (OSError, ET.ParseError) as error:
            fail(f"cannot read report {candidate}: {error}")
    results = {}
    for case in (case for root in roots for case in root.iter("testcase")):
        key = (case.get("classname", ""), case.get("name", ""))
        if key in results:
            fail(f"duplicate test in report: {key[0]}.{key[1]}")
        if case.find("skipped") is not None:
            outcome = "skipped"
        elif case.find("failure") is not None or case.find("error") is not None:
            outcome = "failed"
        else:
            outcome = "passed"
        results[key] = outcome
    if not results:
        fail(f"{path} records no test cases: the suite did not run")
    return results


def parse_since(value):
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"--since is not an ISO-8601 timestamp: {value}", 2)
    if moment.tzinfo is None:
        fail("--since needs a time zone (use the trailing Z)", 2)
    return moment


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", required=True)
    parser.add_argument("--emit-declared")
    parser.add_argument("--declared")
    parser.add_argument("--expect", choices=["failing", "passing"])
    parser.add_argument("--since")
    parser.add_argument("--tests", default="Tests", help="test sources that must not skip (default: Tests)")
    args = parser.parse_args()

    if not os.path.isdir(args.tests):
        fail(f"--tests {args.tests} is not a directory", 2)
    skips = []
    for directory, _, files in os.walk(args.tests):
        for name in files:
            if name.endswith(".swift"):
                with open(os.path.join(directory, name), encoding="utf-8") as handle:
                    skips += [f"{os.path.join(directory, name)}:{n}" for n, line in enumerate(handle, 1) if "XCTSkip" in line]
    if skips:
        fail("a skipped test would count as passed; remove XCTSkip: " + ", ".join(skips))

    results = read_report(args.report)

    if args.emit_declared:
        if args.declared or args.expect or args.since:
            fail("--emit-declared cannot be combined with verification flags", 2)
        if os.path.exists(args.emit_declared):
            fail(f"{args.emit_declared} exists; a declared list is never rewritten", 2)
        declared = [{"suite": suite, "name": name} for (suite, name), outcome in sorted(results.items()) if outcome == "failed"]
        if not declared:
            fail("no test failed: nothing to declare (is this really a RED run?)")
        with open(args.emit_declared, "w", encoding="utf-8") as handle:
            json.dump(declared, handle, indent=2)
            handle.write("\n")
        print(f"[OK] declared {len(declared)} failing tests of {len(results)} in the report -> {args.emit_declared}")
        return

    if not (args.declared and args.expect and args.since):
        fail("give --emit-declared, or --declared with --expect and --since", 2)

    with open(args.declared, encoding="utf-8") as handle:
        declared = [(entry["suite"], entry["name"]) for entry in json.load(handle)]
    if not declared:
        fail("the declared list is empty")

    since = parse_since(args.since)
    modified = datetime.datetime.fromtimestamp(os.path.getmtime(args.report), datetime.timezone.utc)
    if modified < since:
        fail(f"report written {modified.isoformat()} is older than --since {since.isoformat()}")
    freshness = f"written {modified.isoformat()} >= {since.isoformat()}"

    wanted = "failed" if args.expect == "failing" else "passed"
    problems = []
    for suite, name in declared:
        outcome = results.get((suite, name))
        if outcome is None:
            problems.append(f"missing from report: {suite}.{name}")
        elif outcome != wanted:
            problems.append(f"{outcome}, want {wanted}: {suite}.{name}")
    if args.expect == "passing":
        problems += [f"failed (undeclared): {s}.{n}" for (s, n), o in sorted(results.items()) if o == "failed" and (s, n) not in declared]
    if problems:
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        fail(f"{len(problems)} problem(s) against {args.declared}")

    print(f"[OK] {len(declared)} declared tests {wanted}; {len(results)} in report; freshness: {freshness}")


if __name__ == "__main__":
    main()
