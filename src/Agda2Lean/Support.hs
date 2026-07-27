{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Support
  ( SupportClassification (..)
  , SupportRow (..)
  , SupportReport (..)
  , inspectSupport
  , renderSupportReport
  , supportClassificationText
  ) where

import Agda2Lean.IR
import Agda2Lean.Platform (platformMappings)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector

data SupportClassification
  = SupportedCorrespondence
  | ReconstructionBoundary
  | DeliberatelyUnsupported
  | Unclassified
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data SupportRow = SupportRow
  { supportCategory :: Text
  , supportItem :: Text
  , supportCount :: Int
  , supportClassification :: SupportClassification
  , supportDetail :: Text
  }
  deriving stock (Eq, Ord, Show)

data SupportReport = SupportReport
  { supportModule :: CanonicalName
  , supportRows :: [SupportRow]
  , supportOverall :: SupportClassification
  }
  deriving stock (Eq, Show)

inspectSupport :: ModuleIR -> SupportReport
inspectSupport moduleIR =
  SupportReport
    { supportModule = moduleName moduleIR
    , supportRows = rows
    , supportOverall = foldMapClassification (map supportClassification rows)
    }
  where
    declarations = Vector.toList (moduleDeclarations moduleIR)
    terms = Map.elems (moduleTerms moduleIR)
    declarationBuiltins =
      [ builtin
      | declaration <- declarations
      , Just builtin <- [declarationBuiltin declaration]
      ]
    termBuiltins = [builtin | Builtin builtin <- terms]
    features = foldMap declarationFeatures declarations
    mappings = map declarationMapping declarations
    roles = map declarationRole declarations
    imports = Set.toList (moduleImports moduleIR)

    rows =
      [ SupportRow "module" (unCanonicalName (moduleName moduleIR)) 1
          SupportedCorrespondence "canonical module decoded and validated"
      ]
        <> countedRows "import" importStatus unCanonicalName imports
        <> countedRows "builtin-declaration" builtinStatus (Text.pack . show) declarationBuiltins
        <> countedRows "builtin-term" builtinStatus (Text.pack . show) termBuiltins
        <> countedRows "ir" irStatus coreTermName terms
        <> countedRows "declaration-role" roleStatus (Text.pack . show) roles
        <> countedRows "feature" featureStatus (Text.pack . show) (Set.toList features)
        <> countedRows "mapping" mappingStatus (Text.pack . show) mappings
        <> reconstructionRows declarations
        <> extensionRows terms

importStatus :: CanonicalName -> (SupportClassification, Text)
importStatus imported
  | any (`Text.isPrefixOf` name) unsupportedBuiltinFamilies =
      (DeliberatelyUnsupported, "imported builtin family has no promoted semantic identities")
  | "Agda.Builtin.Reflection" `Text.isPrefixOf` name =
      (DeliberatelyUnsupported, "reflection/TCM semantics have no reviewed Lean metaprogram lowering")
  | "Agda.Builtin.Cubical" `Text.isPrefixOf` name =
      (DeliberatelyUnsupported, "cubical interval/path/composition semantics are intentionally blocked")
  | "Agda.Builtin.Size" `Text.isPrefixOf` name =
      (DeliberatelyUnsupported, "size erasure or explicit size semantics are not implemented")
  | "Agda.Builtin.Coinduction" `Text.isPrefixOf` name =
      (DeliberatelyUnsupported, "coinductive productivity/bisimulation lowering is not implemented")
  | "Agda.Builtin.IO" `Text.isPrefixOf` name =
      (DeliberatelyUnsupported, "IO effect and foreign-call correspondence is not implemented")
  | otherwise =
      (SupportedCorrespondence, "import does not itself cross a declared semantic boundary")
  where
    name = unCanonicalName imported
    unsupportedBuiltinFamilies =
      [ "Agda.Builtin.Unit"
      , "Agda.Builtin.Sigma"
      , "Agda.Builtin.List"
      , "Agda.Builtin.Maybe"
      , "Agda.Builtin.Int"
      , "Agda.Builtin.Char"
      , "Agda.Builtin.String"
      , "Agda.Builtin.FromNat"
      , "Agda.Builtin.FromNeg"
      , "Agda.Builtin.FromString"
      ]

builtinStatus :: BuiltinId -> (SupportClassification, Text)
builtinStatus builtin
  | Map.member builtin platformMappings =
      (SupportedCorrespondence, "registered semantic identity; correspondence remains case-specific")
  | otherwise =
      (DeliberatelyUnsupported, "builtin identity is absent from the effective platform registry")

irStatus :: CoreTerm -> (SupportClassification, Text)
irStatus = \case
  Var _ -> supported "variable reference"
  Sort _ -> supported "universe/sort"
  Pi _ _ -> supported "dependent function type"
  Sigma _ _ -> supported "dependent pair term form"
  Lam _ _ -> supported "lambda"
  App _ _ -> supported "application"
  Constructor _ _ -> supported "constructor application"
  Eliminator _ _ -> (Unclassified, "eliminator rendering is shape-dependent")
  Equality _ _ _ -> supported "ordinary equality"
  Axiom _ -> (ReconstructionBoundary, "axiom target requires an explicit trust decision")
  Builtin builtin -> builtinStatus builtin
  Extension extension -> extensionStatus extension
  where
    supported detail = (SupportedCorrespondence, detail)

roleStatus :: DeclarationRole -> (SupportClassification, Text)
roleStatus = \case
  ComputationalData -> supported "data declaration surface"
  ComputationalFunction -> (ReconstructionBoundary, "body support depends on extracted clauses")
  ComputationalWitness -> (ReconstructionBoundary, "witness body may require reconstruction")
  LogicalProposition -> supported "proposition statement"
  Theorem -> (ReconstructionBoundary, "proof body may require reconstruction")
  AxiomDeclaration -> (ReconstructionBoundary, "explicit axiom/trust boundary")
  Certificate -> (ReconstructionBoundary, "certificate proof may require reconstruction")
  Adapter -> (Unclassified, "adapter semantics are case-specific")
  where
    supported detail = (SupportedCorrespondence, detail)

featureStatus :: Feature -> (SupportClassification, Text)
featureStatus = \case
  OrdinaryEquality -> supported "native Lean equality correspondence"
  StructuralRecursion -> (ReconstructionBoundary, "requires clause/body lowering evidence")
  WellFoundedRecursion -> (ReconstructionBoundary, "requires a portable measure or termination proof")
  Cubical -> unsupported "cubical interval/path semantics have no reviewed Lean lowering"
  RewriteRule -> unsupported "Agda rewrite computation has no reviewed theorem-backed lowering"
  Coinduction -> unsupported "coinductive productivity/bisimulation lowering is not implemented"
  UnsafeUniverse -> unsupported "unsafe universe construct cannot be translated faithfully"
  where
    supported detail = (SupportedCorrespondence, detail)
    unsupported detail = (DeliberatelyUnsupported, detail)

mappingStatus :: MappingMode -> (SupportClassification, Text)
mappingStatus = \case
  Exact -> (SupportedCorrespondence, "exact mapping requested")
  Encoded -> (SupportedCorrespondence, "explicit encoded representation")
  Reconstruct -> (ReconstructionBoundary, "native Lean reconstruction required")
  Quarantined -> (DeliberatelyUnsupported, "quarantined from normal emission")
  Unsupported -> (DeliberatelyUnsupported, "explicitly unsupported")

extensionStatus :: ExtensionTerm -> (SupportClassification, Text)
extensionStatus = \case
  CubicalPrimitive name _ -> unsupported ("cubical primitive: " <> name)
  RewritePrimitive name _ -> unsupported ("rewrite primitive: " <> unCanonicalName name)
  CoinductivePrimitive name _ -> unsupported ("coinductive primitive: " <> name)
  UnsafeUniversePrimitive description -> unsupported description
  where
    unsupported detail = (DeliberatelyUnsupported, detail)

reconstructionRows :: [CoreDeclaration] -> [SupportRow]
reconstructionRows declarations =
  [ SupportRow "reconstruction" (unCanonicalName (declarationName declaration)) 1
      ReconstructionBoundary reason
  | declaration <- declarations
  , reason <- reconstructionReason declaration
  ]
  where
    reconstructionReason declaration
      | declarationMapping declaration == Reconstruct = ["mapping mode requests reconstruction"]
      | declarationBody declaration == Nothing
          && declarationRole declaration `elem`
              [ComputationalFunction, ComputationalWitness, Theorem, Certificate] =
          ["portable body is absent"]
      | otherwise = []

extensionRows :: [CoreTerm] -> [SupportRow]
extensionRows terms =
  [ SupportRow "extension" (extensionName extension) 1 classification detail
  | Extension extension <- terms
  , let (classification, detail) = extensionStatus extension
  ]
  where
    extensionName = \case
      CubicalPrimitive name _ -> "cubical:" <> name
      RewritePrimitive name _ -> "rewrite:" <> unCanonicalName name
      CoinductivePrimitive name _ -> "coinductive:" <> name
      UnsafeUniversePrimitive _ -> "unsafe-universe"

countedRows :: Ord a => Text -> (a -> (SupportClassification, Text)) -> (a -> Text) -> [a] -> [SupportRow]
countedRows category classify render values =
  [ SupportRow category (render value) count classification detail
  | (value, count) <- Map.toAscList (Map.fromListWith (+) [(value, 1 :: Int) | value <- values])
  , let (classification, detail) = classify value
  ]

coreTermName :: CoreTerm -> Text
coreTermName = \case
  Var _ -> "Var"
  Sort _ -> "Sort"
  Pi _ _ -> "Pi"
  Sigma _ _ -> "Sigma"
  Lam _ _ -> "Lam"
  App _ _ -> "App"
  Constructor _ _ -> "Constructor"
  Eliminator _ _ -> "Eliminator"
  Equality _ _ _ -> "Equality"
  Axiom _ -> "Axiom"
  Builtin _ -> "Builtin"
  Extension _ -> "Extension"

foldMapClassification :: [SupportClassification] -> SupportClassification
foldMapClassification classifications
  | DeliberatelyUnsupported `elem` classifications = DeliberatelyUnsupported
  | ReconstructionBoundary `elem` classifications = ReconstructionBoundary
  | Unclassified `elem` classifications = Unclassified
  | otherwise = SupportedCorrespondence

supportClassificationText :: SupportClassification -> Text
supportClassificationText = \case
  SupportedCorrespondence -> "supported-correspondence"
  ReconstructionBoundary -> "reconstruction-boundary"
  DeliberatelyUnsupported -> "deliberately-unsupported"
  Unclassified -> "unclassified"

renderSupportReport :: SupportReport -> Text
renderSupportReport report =
  Text.unlines
    ( [ "# module\t" <> unCanonicalName (supportModule report)
      , "# overall\t" <> supportClassificationText (supportOverall report)
      , "category\titem\tcount\tclassification\tdetail"
      ]
        <> map renderRow (sortOn rowKey (supportRows report))
    )
  where
    rowKey row = (supportCategory row, supportItem row, supportDetail row)
    renderRow row =
      Text.intercalate
        "\t"
        [ supportCategory row
        , supportItem row
        , Text.pack (show (supportCount row))
        , supportClassificationText (supportClassification row)
        , Text.replace "\n" " " (supportDetail row)
        ]
