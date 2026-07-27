{-# LANGUAGE OverloadedStrings #-}

module AgdaFixture
  ( identitySnapshot
  , reconstructSnapshot
  ) where

import Agda2Lean.Agda.Snapshot
import Agda2Lean.IR
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import qualified Data.Vector as Vector

carrier :: AgdaTerm
carrier = AgdaDef (CanonicalName "DASHI.Example.Carrier") Vector.empty

identityBinder :: AgdaBinder
identityBinder =
  AgdaBinder
    { agdaBinderName = "x"
    , agdaBinderType = carrier
    , agdaBinderVisibility = Explicit
    , agdaBinderRelevance = Relevant
    }

identitySnapshot :: AgdaModule
identitySnapshot =
  AgdaModule
    { agdaModuleName = CanonicalName "DASHI.Example.Identity"
    , agdaModuleBuiltins = Map.empty
    , agdaModuleImports = Set.singleton (CanonicalName "Agda.Primitive")
    , agdaModuleDeclarations =
        Vector.singleton
          AgdaDeclaration
            { agdaDeclarationName = CanonicalName "DASHI.Example.Identity.identity"
            , agdaDeclarationBuiltin = Nothing
            , agdaDeclarationRole = ComputationalFunction
            , agdaDeclarationUniverses = Vector.empty
            , agdaDeclarationModuleParameters = Vector.empty
            , agdaDeclarationType = AgdaPi identityBinder carrier
            , agdaDeclarationBody =
                Just (AgdaLam identityBinder (AgdaVar 0 Vector.empty))
            , agdaDeclarationAdditionalDependencies = Set.empty
            , agdaDeclarationFeatures = Set.empty
            , agdaDeclarationSource =
                SourceSpan "DASHI/Example/Identity.agda" 5 6
            }
    }

reconstructSnapshot :: AgdaModule
reconstructSnapshot =
  identitySnapshot
    { agdaModuleDeclarations =
        Vector.singleton
          AgdaDeclaration
            { agdaDeclarationName = CanonicalName "DASHI.Example.Identity.pathIdentity"
            , agdaDeclarationBuiltin = Nothing
            , agdaDeclarationRole = Theorem
            , agdaDeclarationUniverses = Vector.empty
            , agdaDeclarationModuleParameters = Vector.empty
            , agdaDeclarationType = AgdaPi identityBinder carrier
            , agdaDeclarationBody =
                Just
                  ( AgdaLam
                      identityBinder
                      ( AgdaUnsupported
                          Cubical
                          "primComp"
                          (Vector.singleton (AgdaVar 0 Vector.empty))
                      )
                  )
            , agdaDeclarationAdditionalDependencies = Set.empty
            , agdaDeclarationFeatures = Set.empty
            , agdaDeclarationSource =
                SourceSpan "DASHI/Example/Identity.agda" 8 9
            }
    }
