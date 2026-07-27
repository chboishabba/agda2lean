{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Lean.Checked
  ( emitLeanModuleChecked
  ) where

import Agda2Lean.IR
import Agda2Lean.Lean.Emit
import Agda2Lean.Platform
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector

-- | The fail-closed production boundary for Lean emission. It verifies the
-- complete compatibility tuple, requires an effective mapping for every
-- encountered builtin identity, and checks that every builtin decision produced
-- exactly one semantic receipt.
emitLeanModuleChecked :: VersionContext -> EmitOptions -> ModuleIR -> Either Text LeanOutput
emitLeanModuleChecked versionContext options moduleIR = do
  ensureCompatible versionContext
  ensureRegistryCoverage options moduleIR
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
      | declaration <- Vector.toList (moduleDeclarations moduleIR)
      , Just builtin <- [declarationBuiltin declaration]
      , Map.notMember builtin (emitRegistry options)
      ]

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
