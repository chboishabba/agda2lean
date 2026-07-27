{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Agda.Snapshot
  ( AgdaBinder (..)
  , AgdaDeclaration (..)
  , AgdaElimination (..)
  , AgdaModule (..)
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
  | AgdaEquality AgdaTerm AgdaTerm AgdaTerm
  | AgdaLiteral Text Text
  | AgdaUnsupported Feature Text (Vector AgdaTerm)
  deriving stock (Eq, Ord, Show, Generic)

data AgdaDeclaration = AgdaDeclaration
  { agdaDeclarationName :: CanonicalName
  , agdaDeclarationBuiltin :: Maybe BuiltinId
  , agdaDeclarationRole :: DeclarationRole
  , agdaDeclarationUniverses :: Vector Text
  , agdaDeclarationModuleParameters :: Vector AgdaBinder
  , agdaDeclarationType :: AgdaTerm
  , agdaDeclarationBody :: Maybe AgdaTerm
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
