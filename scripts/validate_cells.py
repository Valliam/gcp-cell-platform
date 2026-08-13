#!/usr/bin/env python3
"""Structural validation of the cell registry.

Runs with no cloud credentials, so it gates every pull request. It covers the
checks that are cross-file or arithmetic, which Rego handles badly:

  1. schema      — required fields and types in every cell.yaml
  2. residency   — a cell's region and standby region must be inside its
                   venture's declared residency envelope
  3. addressing  — no two cells anywhere may overlap on any CIDR range
  4. naming      — derived project IDs must satisfy GCP's 6..30 char limit

Environment-conditional security rules live in policy/cell.rego instead.

    python3 scripts/validate_cells.py [--root .]
"""

from __future__ import annotations

import argparse
import ipaddress
import pathlib
import re
import sys

import yaml

# GCP project IDs are 6-30 chars, lowercase alphanumeric and hyphens, and must
# start with a letter. They are also globally unique and *permanently* consumed
# once used, which is why the prefix is an input rather than a constant.
PROJECT_ID_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")
PROJECT_ID_PREFIX = "cp"  # matches var.project_prefix in stacks/cell

CIDR_FIELDS = ("subnet_cidr", "pods_cidr", "services_cidr", "master_cidr")

REQUIRED = {
    "venture": str,
    "cell": str,
    "env": str,
    "region": str,
    "dr": dict,
    "network": dict,
    "gke": dict,
    "database": dict,
    "security": dict,
    "observability": dict,
    "budget": dict,
}

VALID_ENVS = {"dev", "staging", "prod"}


class Findings:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def error(self, where: str, msg: str) -> None:
        self.errors.append(f"{where}: {msg}")

    def report(self) -> int:
        if not self.errors:
            return 0
        print(f"\n{len(self.errors)} problem(s) found:\n", file=sys.stderr)
        for e in self.errors:
            print(f"  ✗ {e}", file=sys.stderr)
        print("", file=sys.stderr)
        return 1


def load(path: pathlib.Path) -> dict:
    with path.open() as fh:
        return yaml.safe_load(fh) or {}


def allowed_regions(venture: dict) -> set[str]:
    """Turn org-policy location values into bare region names.

    `in:australia-southeast1-locations` is the value group the
    gcp.resourceLocations constraint understands; we compare against the region
    it corresponds to so a cell.yaml can be checked without calling GCP.
    """
    out: set[str] = set()
    for value in venture.get("data_residency", {}).get("allowed_locations", []):
        m = re.fullmatch(r"in:(?P<region>[a-z0-9-]+)-locations", value)
        if m:
            out.add(m.group("region"))
    return out


def check_schema(cell: dict, where: str, f: Findings) -> None:
    for field, want in REQUIRED.items():
        if field not in cell:
            f.error(where, f"missing required field {field!r}")
        elif not isinstance(cell[field], want):
            got = type(cell[field]).__name__
            f.error(where, f"field {field!r} must be {want.__name__}, got {got}")

    if cell.get("env") not in VALID_ENVS:
        f.error(where, f"env must be one of {sorted(VALID_ENVS)}, got {cell.get('env')!r}")

    pools = cell.get("gke", {}).get("node_pools") or []
    if not pools:
        f.error(where, "gke.node_pools must declare at least one pool")
    for pool in pools:
        for field in ("name", "machine_type", "min_nodes", "max_nodes"):
            if field not in pool:
                f.error(where, f"node pool {pool.get('name', '?')!r} missing {field!r}")


def check_residency(cell: dict, venture: dict, where: str, f: Findings) -> None:
    allowed = allowed_regions(venture)
    if not allowed:
        f.error(where, "venture declares no data_residency.allowed_locations")
        return

    region = cell.get("region")
    if region and region not in allowed:
        f.error(
            where,
            f"region {region!r} is outside the venture residency envelope "
            f"{sorted(allowed)} — widen venture.yaml deliberately or pick another region",
        )

    standby = (cell.get("dr") or {}).get("standby_region")
    if standby and standby not in allowed:
        f.error(
            where,
            f"dr.standby_region {standby!r} is outside the venture residency envelope "
            f"{sorted(allowed)} — a DR replica leaving the jurisdiction is still a breach",
        )


def check_naming(cell: dict, where: str, f: Findings) -> None:
    project_id = f"{PROJECT_ID_PREFIX}-{cell.get('venture')}-{cell.get('cell')}"
    if not PROJECT_ID_RE.fullmatch(project_id):
        f.error(
            where,
            f"derived project id {project_id!r} ({len(project_id)} chars) is not a valid "
            "GCP project id (6-30 chars, must start with a letter)",
        )


def collect_networks(cell: dict, where: str, f: Findings) -> list[tuple[str, ipaddress.IPv4Network]]:
    nets = []
    network = cell.get("network") or {}
    for field in CIDR_FIELDS:
        raw = network.get(field)
        if raw is None:
            f.error(where, f"network.{field} is required")
            continue
        try:
            net = ipaddress.ip_network(raw, strict=True)
        except ValueError as exc:
            f.error(where, f"network.{field}={raw!r} is not a valid CIDR ({exc})")
            continue
        nets.append((f"{where}:{field}", net))

    master = network.get("master_cidr")
    if master:
        try:
            if ipaddress.ip_network(master, strict=True).prefixlen != 28:
                f.error(where, f"network.master_cidr must be a /28, got {master}")
        except ValueError:
            pass  # already reported above
    return nets


def check_overlaps(all_nets: list[tuple[str, ipaddress.IPv4Network]], f: Findings) -> None:
    for i, (a_name, a_net) in enumerate(all_nets):
        for b_name, b_net in all_nets[i + 1 :]:
            if a_net.overlaps(b_net):
                f.error(
                    "addressing",
                    f"{a_name} ({a_net}) overlaps {b_name} ({b_net}) — cells must stay "
                    "non-overlapping so any two can later be peered without renumbering",
                )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".", type=pathlib.Path)
    args = parser.parse_args()

    ventures_dir = args.root / "ventures"
    if not ventures_dir.is_dir():
        print(f"no ventures/ directory under {args.root}", file=sys.stderr)
        return 1

    f = Findings()
    all_nets: list[tuple[str, ipaddress.IPv4Network]] = []
    seen: set[tuple[str, str]] = set()
    count = 0

    for venture_file in sorted(ventures_dir.glob("*/venture.yaml")):
        venture = load(venture_file)
        venture_name = venture_file.parent.name

        if venture.get("venture") != venture_name:
            f.error(
                str(venture_file),
                f"venture field {venture.get('venture')!r} does not match directory "
                f"{venture_name!r}",
            )

        for cell_file in sorted((venture_file.parent / "cells").glob("*.yaml")):
            count += 1
            where = str(cell_file.relative_to(args.root))
            cell = load(cell_file)

            if cell.get("venture") != venture_name:
                f.error(where, f"venture field must be {venture_name!r}")
            if cell.get("cell") != cell_file.stem:
                f.error(where, f"cell field must match filename stem {cell_file.stem!r}")

            key = (venture_name, cell_file.stem)
            if key in seen:
                f.error(where, "duplicate venture/cell pair")
            seen.add(key)

            check_schema(cell, where, f)
            check_residency(cell, venture, where, f)
            check_naming(cell, where, f)
            all_nets.extend(collect_networks(cell, where, f))

    check_overlaps(all_nets, f)

    rc = f.report()
    if rc == 0:
        print(f"✓ {count} cell(s) across {len(list(ventures_dir.glob('*/venture.yaml')))} venture(s): "
              f"schema, residency, addressing and naming all valid")
    return rc


if __name__ == "__main__":
    sys.exit(main())
