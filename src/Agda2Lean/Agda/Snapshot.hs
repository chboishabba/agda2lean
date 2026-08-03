{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Agda.Snapshot
  ( AgdaBinder (..)
  , AgdaClause (..)
  , AgdaConstructorSchema (..)
  , AgdaDataSchema (..)
  , AgdaDeclaration (..)
  , AgdaDeclarationDefinition (..)
  , AgdaElimination (..)
  , AgdaLevelExpr (..)
  , AgdaModule (..)
  , AgdaPattern (..)
  , AgdaProjectionSchema (..)
  , AgdaRecordField (..)
  , AgdaRecordSchema (..)
  , AgdaTerm (..)
  ) where

import Agda2Lean.IR
  ( CanonicalName
  , BuiltinId
  , DeclarationRole
  , Feature
  , Relevance
  , SourceSpan
  , Universe
  , Visibility
  )
import Data.Set (Set)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Vector (Vector)
import Data.Word (Word64)
import GHC.Generics (Generic)

-- | Stable, version-independent view of Agda's typechecked internal syntax.
-- The version-specific Agda backend is responsible only for constructing
-- these values. No concrete Agda syntax is parsed by the core pipeline.
data AgdaBinder = AgdaBinder
  { agdaBinderName :: Text
  , agdaBinderType :: AgdaTerm
  , agdaBinderVisibility :: Visibility
  , agdaBinderRelevance :: Relevance
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaElimination
  = AgdaApply Visibility Relevance AgdaTerm
  | AgdaProject CanonicalName
  | AgdaIntervalApply AgdaTerm AgdaTerm AgdaTerm
  deriving stock (Eq, Ord, Show, Generic)

data AgdaTerm
  = AgdaVar Int (Vector AgdaElimination)
  | AgdaLam AgdaBinder AgdaTerm
  | AgdaDef CanonicalName (Vector AgdaElimination)
  | AgdaCon CanonicalName (Vector AgdaElimination)
  | AgdaPi AgdaBinder AgdaTerm
  | AgdaSigma AgdaBinder AgdaTerm
  | AgdaSort Universe
  | AgdaLevel AgdaLevelExpr
  | AgdaEquality AgdaTerm AgdaTerm AgdaTerm
  | AgdaLiteral Text Text
  | AgdaUnsupported Feature Text (Vector AgdaTerm)
  deriving stock (Eq, Ord, Show, Generic)

-- | De Bruijn-indexed level syntax.  Binder identities are assigned only
-- after the version-specific Agda snapshot crosses into the core extractor.
data AgdaLevelExpr
  = AgdaLevelZero
  | AgdaLevelSuccessor AgdaLevelExpr
  | AgdaLevelMaximum (Vector AgdaLevelExpr)
  | AgdaLevelVariable Int
  deriving stock (Eq, Ord, Show, Generic)

-- | The deliberately small, portable pattern fragment.  Dot patterns,
-- copatterns, path patterns, and higher-inductive patterns are classified as
-- blocked definitions by the Agda backend instead of being approximated.
data AgdaPattern
  = AgdaPatternVariable Int
  | AgdaPatternConstructor CanonicalName (Vector AgdaPattern)
  | AgdaPatternBuiltin BuiltinId (Vector AgdaPattern)
  | AgdaPatternLiteral Text Text
  | AgdaPatternWildcard
  deriving stock (Eq, Ord, Show, Generic)

data AgdaClause = AgdaClause
  { agdaClauseTelescope :: Vector AgdaBinder
  , agdaClausePatterns :: Vector AgdaPattern
  , agdaClauseBody :: AgdaTerm
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaDataSchema = AgdaDataSchema
  { agdaDataParameterCount :: Word64
  , agdaDataConstructors :: Vector CanonicalName
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaConstructorSchema = AgdaConstructorSchema
  { agdaConstructorOwner :: CanonicalName
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaRecordField = AgdaRecordField
  { agdaRecordFieldName :: CanonicalName
  , agdaRecordFieldType :: AgdaTerm
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaRecordSchema = AgdaRecordSchema
  { agdaRecordParameters :: Vector AgdaBinder
  , agdaRecordConstructor :: CanonicalName
  , agdaRecordFields :: Vector AgdaRecordField
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaProjectionSchema = AgdaProjectionSchema
  { agdaProjectionRecord :: CanonicalName
  , agdaProjectionField :: CanonicalName
  , agdaProjectionIndex :: Word64
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | A proof-aware definition snapshot.  'AgdaBlockedDefinition' is not an
-- axiom: it is a typed, fail-closed obligation which the emitter must reject.
data AgdaDeclarationDefinition
  = AgdaTermDefinition AgdaTerm
  | AgdaClauseDefinition (Vector AgdaClause)
  | AgdaDataDefinition AgdaDataSchema
  | AgdaConstructorDefinition AgdaConstructorSchema
  | AgdaRecordDefinition AgdaRecordSchema
  | AgdaProjectionDefinition AgdaProjectionSchema
  | AgdaAxiomDefinition
  | AgdaBlockedDefinition Text Text
  deriving stock (Eq, Ord, Show, Generic)

data AgdaDeclaration = AgdaDeclaration
  { agdaDeclarationName :: CanonicalName
  , agdaDeclarationBuiltin :: Maybe BuiltinId
  , agdaDeclarationRole :: DeclarationRole
  , agdaDeclarationUniverses :: Vector Text
  , agdaDeclarationModuleParameters :: Vector AgdaBinder
  , agdaDeclarationType :: AgdaTerm
  , agdaDeclarationDefinition :: AgdaDeclarationDefinition
  , agdaDeclarationAdditionalDependencies :: Set CanonicalName
  , agdaDeclarationFeatures :: Set Feature
  , agdaDeclarationSource :: SourceSpan
  }
  deriving stock (Eq, Ord, Show, Generic)

data AgdaModule = AgdaModule
  { agdaModuleName :: CanonicalName
  , agdaModuleBuiltins :: Map CanonicalName BuiltinId
  , agdaModuleImports :: Set CanonicalName
  , agdaModuleDeclarations :: Vector AgdaDeclaration
  }
  deriving stock (Eq, Ord, Show, Generic)
