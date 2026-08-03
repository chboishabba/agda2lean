{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Lean.Checked
  ( emitLeanModuleChecked
  ) where

import Agda2Lean.IR
import Agda2Lean.Lean.Emit
import Agda2Lean.Platform
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector

-- | The fail-closed production boundary for Lean emission. It verifies the
-- complete compatibility tuple, requires an effective mapping for every
-- declaration-level and term-level builtin identity, prevents the low-level
-- renderer from observing a target that differs from the effective registry,
-- and checks that every builtin declaration decision produced exactly one
-- semantic receipt.
emitLeanModuleChecked :: VersionContext -> EmitOptions -> ModuleIR -> Either Text LeanOutput
emitLeanModuleChecked versionContext options moduleIR = do
  ensureCompatible versionContext
  ensureRegistryCoverage options moduleIR
  ensureRendererConsistency options moduleIR
  let output = emitLeanModule options moduleIR
  ensureReceiptCompleteness moduleIR output
  pure output

ensureCompatible :: VersionContext -> Either Text ()
ensureCompatible context =
  case checkVersionCompatibility context of
    Compatible -> Right ()
    MigrationRequired message -> Left message
    Incompatible message -> Left message

ensureRegistryCoverage :: EmitOptions -> ModuleIR -> Either Text ()
ensureRegistryCoverage options moduleIR =
  case missing of
    [] -> Right ()
    _ ->
      Left
        ( "effective registry does not cover encountered builtins: "
            <> Text.unwords (map (Text.pack . show) missing)
        )
  where
    missing =
      [ builtin
      | builtin <- Set.toAscList (encounteredBuiltins moduleIR)
      , Map.notMember builtin (emitRegistry options)
      ]

-- Platform rules are protected against semantic retargeting. Checked emission
-- verifies that an injected layered registry still agrees with the audited
-- platform target for every term-level builtin before rendering starts.
ensureRendererConsistency :: EmitOptions -> ModuleIR -> Either Text ()
ensureRendererConsistency options moduleIR =
  case divergent of
    [] -> Right ()
    _ ->
      Left
        ( "effective registry diverges from the term renderer for builtins: "
            <> Text.unwords (map (Text.pack . show) divergent)
        )
  where
    divergent =
      [ builtin
      | builtin <- Set.toAscList (termBuiltins moduleIR <> definitionBuiltins moduleIR)
      , effectiveTarget builtin /= platformTargetFor builtin
      ]
    effectiveTarget builtin = platformTarget <$> Map.lookup builtin (emitRegistry options)
    platformTargetFor builtin = platformTarget <$> lookupPlatformMapping builtin

encounteredBuiltins :: ModuleIR -> Set.Set BuiltinId
encounteredBuiltins moduleIR =
  declarationBuiltins moduleIR
    <> termBuiltins moduleIR
    <> definitionBuiltins moduleIR

declarationBuiltins :: ModuleIR -> Set.Set BuiltinId
declarationBuiltins moduleIR =
  Set.fromList
    [ builtin
    | declaration <- Vector.toList (moduleDeclarations moduleIR)
    , Just builtin <- [declarationBuiltin declaration]
    ]

termBuiltins :: ModuleIR -> Set.Set BuiltinId
termBuiltins moduleIR =
  Set.fromList
    [ builtin
    | Builtin builtin <- Map.elems (moduleTerms moduleIR)
    ]

definitionBuiltins :: ModuleIR -> Set.Set BuiltinId
definitionBuiltins moduleIR =
  foldMap
    (definitionPatternBuiltins . declarationDefinition)
    (moduleDeclarations moduleIR)

definitionPatternBuiltins :: DeclarationDefinition -> Set.Set BuiltinId
definitionPatternBuiltins definition =
  case definition of
    ClauseDefinition clauses ->
      foldMap (foldMap patternBuiltins . clausePatterns) clauses
    _ -> Set.empty

patternBuiltins :: CorePattern -> Set.Set BuiltinId
patternBuiltins pattern' =
  case pattern' of
    PatternVariable _ -> Set.empty
    PatternConstructor _ children -> foldMap patternBuiltins children
    PatternBuiltin builtin children ->
      Set.insert builtin (foldMap patternBuiltins children)
    PatternLiteral _ _ -> Set.empty
    PatternWildcard -> Set.empty

ensureReceiptCompleteness :: ModuleIR -> LeanOutput -> Either Text ()
ensureReceiptCompleteness moduleIR output
  | encountered == recorded = Right ()
  | otherwise =
      Left
        ( "builtin receipt completeness failure: encountered "
            <> Text.pack (show encountered)
            <> ", recorded "
            <> Text.pack (show recorded)
        )
  where
    encountered =
      length
        [ ()
        | declaration <- Vector.toList (moduleDeclarations moduleIR)
        , Just _ <- [declarationBuiltin declaration]
        ]
    recorded = Vector.length (leanBuiltinReceipts output)
