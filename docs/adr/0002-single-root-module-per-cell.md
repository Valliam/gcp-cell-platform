# 0002 — One root module for every cell

**Status:** accepted

## Context

Given N cells, Terraform offers two shapes:

1. `stacks/acme-prod-syd/`, `stacks/acme-staging-syd/`, … — one directory per
   cell, each with its own `main.tf` and backend block.
2. One `stacks/cell/`, instantiated N times with a different variable file and a
   different state prefix.

Shape 1 is what most repositories drift into, because the first two cells are
trivially easy to copy.

## Decision

One root module: `stacks/cell/`. The cell is selected by two inputs — a contract
path and a backend prefix:

```console
terraform init -backend-config="prefix=cells/acme/prod-syd"
terraform plan  -var="cell_file=../../ventures/acme/cells/prod-syd.yaml"
```

## Consequences

- A fix is written once and reaches every cell on its next apply. Under shape 1
  a fix has to be applied N times, and the Nth copy is the one that gets missed.
- Cells cannot silently diverge, because there is no per-cell code in which to
  diverge. Everything that differs is visible in one YAML file, side by side
  with every other cell's.
- Staging is structurally identical to prod rather than approximately similar,
  which is the only condition under which staging predicts anything.
- CI iterates cells as a matrix built by globbing `ventures/*/cells/*.yaml`.
  Adding a cell adds a CI job with no workflow change.

The cost is that a change to shared code is a change to every cell at once. That
is handled by promotion order — `promote.yml` applies dev, then staging, then
prod, with an approval gate and a soak between — rather than by keeping the code
separate. Separate code does not prevent a bad change; it only delays and
scatters it.

A second cost: one working directory serves every cell, so CI must
`init -reconfigure` between cells. Forgetting that writes one cell's state over
another's prefix. It is the sharpest edge in this design and the reason the
init/plan pairing lives in a `Makefile` target and a composite action rather
than being retyped.
