# Declared Agda feature support matrix

This file records the current **declared expectations** from `test/conformance/manifest.tsv`. It is not a substitute for generated survey reports or Lean correspondence oracles.

Regenerate the table with:

```sh
bash scripts/render-support-matrix.sh
```

| Case | Phase | Expected classification | Principal gap |
|---|---|---|---|
| `structural.parameterized-datatype` | structural | `reconstruction-boundary` | constructor and body lowering |
| `structural.record` | structural | `reconstruction-boundary` | record/projection lowering and eta policy |
| `structural.nested-namespace` | structural | `reconstruction-boundary` | contained body correspondence oracle |
| `structural.implicit-arguments` | structural | `reconstruction-boundary` | function body lowering |
| `structural.instance-arguments` | structural | `reconstruction-boundary` | instance-synthesis correspondence |
| `structural.mutual-definitions` | structural | `reconstruction-boundary` | mutual clauses and termination structure |
| `structural.local-module` | structural | `reconstruction-boundary` | module parameter instantiation |
| `computation.structural-recursion` | computation | `reconstruction-boundary` | typed clause extraction and equations |
| `computation.dependent-pattern` | computation | `reconstruction-boundary` | dependent motives and refinements |
| `computation.with-abstraction` | computation | `reconstruction-boundary` | generated helper preservation |
| `computation.irrelevant-argument` | computation | `reconstruction-boundary` | proved erasure correspondence |
| `builtins.unit` | builtins | `deliberately-unsupported` | semantic identities and Lean lowering |
| `builtins.sigma` | builtins | `deliberately-unsupported` | semantic identities and Lean lowering |
| `builtins.list` | builtins | `deliberately-unsupported` | semantic identities, recursion and computation oracle |
| `builtins.maybe` | builtins | `deliberately-unsupported` | semantic identities and Lean lowering |
| `builtins.integer` | builtins | `deliberately-unsupported` | constructor and literal correspondence |
| `boundary.rewrite` | boundary | `deliberately-unsupported` | oriented theorem-backed rewrite semantics |
| `boundary.reflection` | boundary | `deliberately-unsupported` | elaborated-result or metaprogram bridge policy |
| `boundary.cubical` | boundary | `deliberately-unsupported` | interval/path/transport/composition model |

## Declared coverage counts

- classified cases: 19 of 19;
- reconstruction-boundary cases: 11;
- deliberately-unsupported cases: 8;
- supported-correspondence cases: 0;
- unclassified cases: 0.

The zero positive count is intentional. The promotion policy forbids `supported-correspondence` until a concrete Lean oracle is listed and checked.

## Evidence layers

1. **Declared:** the manifest states the expected outcome.
2. **Surveyed:** the pinned Agda backend produced CBOR and `agda2lean-support` classified the observed module.
3. **Emitted:** checked Lean emission behaved as expected.
4. **Correspondence-checked:** Lean compilation and the semantic oracle passed.

Only layer 4 is positive semantic support.
