import Mathlib

/-!
# Lean mirror of `Moonshine.agda` (genuine, fully proved)

Faithful transcription of the root Agda module `Moonshine.agda`.  Every
statement there is an elementary arithmetic identity proved by `refl`/`decide`;
they are genuine, machine-checkable facts (no postulates), so they transcribe
directly into proved Lean theorems.

The mathematical content: `196884 = 47 × 59 × 71 + 1`, where `196883 = 47·59·71`
is the dimension of the smallest faithful representation of the Monster group and
`196884` is the first non-trivial Fourier coefficient of the `j`-invariant
(McKay's observation `196884 = 196883 + 1`).
-/

namespace AgdaMirror.Moonshine

/-- The three largest supersingular primes dividing `|M|`. -/
def p47 : Nat := 47
def p59 : Nat := 59
def p71 : Nat := 71

/-- `47 × 59 × 71 = 196883`. -/
def trivectorProduct : Nat := p47 * p59 * p71

/-- The "observer" `+1`. -/
def observer : Nat := 1

/-- The first non-trivial `j`-invariant Fourier coefficient `196884`. -/
def jCoefficient : Nat := trivectorProduct + observer

/-- The moonshine equation: `47 × 59 × 71 + 1 = 196884`. -/
theorem moonshine : jCoefficient = 196884 := rfl

/-- Smallest faithful representation dimension of the Monster. -/
def repDim : Nat := trivectorProduct

theorem rep_dim_check : repDim = 196883 := rfl

/-- McKay's observation `196884 = 196883 + 1`. -/
theorem mckay : repDim + 1 = jCoefficient := rfl

theorem embedding : trivectorProduct + observer = 196884 := rfl

/-- A witness records the exponent counts of the three trivector primes. -/
structure Witness where
  c47 : Nat
  c59 : Nat
  c71 : Nat

/-- `j`-fixed means all three trivector primes are present (exponent `> 0`). -/
def isJFixed (w : Witness) : Bool :=
  decide (0 < w.c47) && decide (0 < w.c59) && decide (0 < w.c71)

/-- The minimal witness: each trivector prime appears exactly once (the `+1`). -/
def theObserver : Witness := ⟨1, 1, 1⟩

theorem observer_is_j_fixed : isJFixed theObserver = true := rfl

end AgdaMirror.Moonshine
