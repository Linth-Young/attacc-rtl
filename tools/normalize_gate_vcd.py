#!/usr/bin/env python3
"""Normalize Yosys flattened -hdlname VCD into an ORFS top-module VCD.

Yosys emits a separate ``$scope dut`` block for every flattened signal.  Open
STA's VCD reader expects one canonical hierarchy.  This utility keeps the DUT
subtree, merges repeated scopes, makes ``attacc_gemv_unit`` the root scope and
filters events for dropped wrapper-only identifiers.
"""

from __future__ import annotations

import argparse
import re
from collections import defaultdict
from pathlib import Path


VAR_RE = re.compile(r"^\$var\s+\S+\s+\S+\s+(\S+)(?:\s+.*)?\s+\$end$")
SCOPE_RE = re.compile(r"^\$scope\s+module\s+(\S+)\s+\$end$")
SCALAR_RE = re.compile(r"^[01xXzZ](\S+)$")
VECTOR_RE = re.compile(r"^[bBrR]\S+\s+(\S+)$")


def node() -> dict[str, object]:
    return {"vars": [], "children": defaultdict(node)}


def emit_scope(out: list[str], name: str, entry: dict[str, object]) -> None:
    out.append(f"$scope module {name} $end\n")
    out.extend(entry["vars"])
    for child_name in sorted(entry["children"]):
        emit_scope(out, child_name, entry["children"][child_name])
    out.append("$upscope $end\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--wrapper", default="attacc_gemv_gate_activity_wrapper")
    parser.add_argument("--dut", default="dut")
    parser.add_argument("--top", default="attacc_gemv_unit")
    args = parser.parse_args()

    lines = args.input.read_text(encoding="utf-8").splitlines(keepends=True)
    try:
        definition_end = next(i for i, line in enumerate(lines) if line.strip() == "$enddefinitions $end")
    except StopIteration as error:
        raise SystemExit("VCD has no $enddefinitions") from error

    root = node()
    declared_codes: set[str] = set()
    stack: list[str] = []
    preamble = [line for line in lines[:definition_end] if not line.startswith(("$scope", "$upscope", "$var"))]
    for line in lines[:definition_end]:
        scope = SCOPE_RE.match(line.strip())
        if scope:
            stack.append(scope.group(1))
            continue
        if line.strip() == "$upscope $end":
            stack.pop()
            continue
        variable = VAR_RE.match(line.strip())
        if not variable:
            continue
        if len(stack) < 2 or stack[0] != args.wrapper or stack[1] != args.dut:
            continue
        entry = root
        for scope_name in stack[2:]:
            entry = entry["children"][scope_name]
        entry["vars"].append(line)
        declared_codes.add(variable.group(1))

    output = [line for line in preamble if line.strip() != "$enddefinitions $end"]
    emit_scope(output, args.top, root)
    output.append("$enddefinitions $end\n")
    kept_events = 0
    for line in lines[definition_end + 1 :]:
        stripped = line.strip()
        match = SCALAR_RE.match(stripped) or VECTOR_RE.match(stripped)
        if match and match.group(1) not in declared_codes:
            continue
        output.append(line)
        kept_events += 1
    args.output.write_text("".join(output), encoding="utf-8")
    print(f"Wrote {len(declared_codes)} VCD variables and {kept_events} post-header events to {args.output}")


if __name__ == "__main__":
    main()
