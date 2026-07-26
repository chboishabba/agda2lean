/-
Copyright (c) 2026 Johl Brown.
Released under the BSD 3-Clause license; see LICENSE.

Deterministic dependency manifest for Lean declarations.

Usage:

  lake env lean --run lean/Agda2Lean/Manifest.lean -- \
    --module My.Project.Module \
    My.Project.theorem My.Project.definition

Repeat `--module MODULE` when the requested constants are spread across
multiple modules. `Lean` is imported at runtime when no module is supplied.
All requested constants are checked before any output is written, so a missing
constant fails atomically.

The output is headerless TSV:

  requested-constant<TAB>relation<TAB>referenced-constant

`relation` is one of `type-direct`, `value-direct`, or `axiom-closure`. Empty
reference sets are represented by one row whose third field is empty. Names are
sorted and deduplicated, making the output independent of argument order and
hash-table iteration order. Tabs, newlines, carriage returns, and backslashes
in names are backslash-escaped.
-/

import Lean
import Lean.Util.CollectAxioms
import Lean.Util.FoldConsts

namespace Agda2Lean.Manifest

open Lean

private structure Arguments where
  modules : Array Name := #[]
  constants : Array Name := #[]

private def usage : String :=
  "usage: Manifest [--module MODULE]... CONSTANT..."

private def parseArguments : List String → Except String Arguments
  | [] => .error s!"{usage}\nerror: at least one constant is required"
  | args => go args {}
where
  go : List String → Arguments → Except String Arguments
    | [], parsed =>
        if parsed.constants.isEmpty then
          .error s!"{usage}\nerror: at least one constant is required"
        else
          .ok parsed
    | "--module" :: [], _ =>
        .error s!"{usage}\nerror: --module requires a module name"
    | "--module" :: moduleName :: rest, parsed =>
        if moduleName.isEmpty then
          .error s!"{usage}\nerror: module names must not be empty"
        else
          go rest { parsed with modules := parsed.modules.push moduleName.toName }
    | "--help" :: _, _ => .error usage
    | "-h" :: _, _ => .error usage
    | argument :: rest, parsed =>
        if argument.startsWith "-" then
          .error s!"{usage}\nerror: unknown option '{argument}'"
        else if argument.isEmpty then
          .error s!"{usage}\nerror: constant names must not be empty"
        else
          go rest { parsed with constants := parsed.constants.push argument.toName }

private def sortedUnique (names : Array Name) : Array Name := Id.run do
  let sorted := names.qsort (· < ·)
  let mut result := #[]
  for name in sorted do
    if result.back? != some name then
      result := result.push name
  return result

private def directTypeReferences (info : ConstantInfo) : Array Name :=
  sortedUnique info.type.getUsedConstants

private def valueExpression? : ConstantInfo → Option Expr
  | .defnInfo info => some info.value
  | .thmInfo info => some info.value
  | .opaqueInfo info => some info.value
  | _ => none

private def directValueReferences (info : ConstantInfo) : Array Name :=
  match valueExpression? info with
  | some value => sortedUnique value.getUsedConstants
  | none => #[]

private def axiomClosure (environment : Environment) (name : Name) : Array Name :=
  let (_, state) := ((CollectAxioms.collect name).run environment).run {}
  sortedUnique state.axioms

private def escapeField (value : String) : String :=
  value
    |>.replace "\\" "\\\\"
    |>.replace "\t" "\\t"
    |>.replace "\n" "\\n"
    |>.replace "\r" "\\r"

private def emitRow (requested : Name) (relation : String)
    (reference? : Option Name) : IO Unit := do
  let reference := reference?.map toString |>.getD ""
  IO.println <|
    escapeField requested.toString ++ "\t" ++ relation ++ "\t" ++
      escapeField reference

private def emitRelation (requested : Name) (relation : String)
    (references : Array Name) : IO Unit := do
  if references.isEmpty then
    emitRow requested relation none
  else
    for reference in references do
      emitRow requested relation (some reference)

private def missingConstants (environment : Environment)
    (requested : Array Name) : Array Name :=
  requested.filter fun name => (environment.checked.get.find? name).isNone

private def emitConstant (environment : Environment) (requested : Name)
    (info : ConstantInfo) : IO Unit := do
  emitRelation requested "type-direct" (directTypeReferences info)
  emitRelation requested "value-direct" (directValueReferences info)
  emitRelation requested "axiom-closure" (axiomClosure environment requested)

private unsafe def run (arguments : Arguments) : IO Unit := do
  let modules :=
    if arguments.modules.isEmpty then #[`Lean]
    else sortedUnique arguments.modules
  let imports := modules.map fun moduleName => ({ module := moduleName } : Import)
  let environment ← importModules imports {}
  let requested := sortedUnique arguments.constants
  let missing := missingConstants environment requested
  unless missing.isEmpty do
    let rendered := String.intercalate ", " (missing.toList.map toString)
    throw <| IO.userError s!"missing Lean constant(s): {rendered}"
  for name in requested do
    let some info := environment.checked.get.find? name
      | throw <| IO.userError s!"internal error: validated constant disappeared: {name}"
    emitConstant environment name info

unsafe def runCli (args : List String) : IO Unit := do
  match parseArguments args with
  | .ok parsed => run parsed
  | .error message => throw <| IO.userError message

end Agda2Lean.Manifest

unsafe def main (args : List String) : IO Unit :=
  Agda2Lean.Manifest.runCli args
