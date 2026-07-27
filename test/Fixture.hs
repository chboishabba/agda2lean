{-# LANGUAGE OverloadedStrings #-}

module Fixture
  ( exampleModule
  , exampleModuleReordered
  ) where

import Agda2Lean.IR
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Vector as Vector

exampleModule :: ModuleIR
exampleModule =
  ModuleIR
    { moduleSchemaVersion = currentSchemaVersion
    , moduleName = CanonicalName "DASHI.Example.Identity"
    , moduleImports = Set.fromList [CanonicalName "Agda.Primitive"]
    , moduleTerms =
        Map.fromList
          [ (TermId 0, Sort UZero)
          , (TermId 1, Axiom (CanonicalName "DASHI.Example.Carrier"))
          , ( TermId 2
            , Pi
                Binder
                  { binderId = BinderId 0
                  , binderName = "x"
                  , binderType = TermId 1
                  , binderVisibility = Explicit
                  , binderRelevance = Relevant
                  }
                (TermId 1)
            )
          , ( TermId 3
            , Lam
                Binder
                  { binderId = BinderId 0
                  , binderName = "x"
                  , binderType = TermId 1
                  , binderVisibility = Explicit
                  , binderRelevance = Relevant
                  }
                (TermId 4)
            )
          , (TermId 4, Var (BinderId 0))
          ]
    , moduleDeclarations =
        Vector.singleton
          CoreDeclaration
            { declarationName = CanonicalName "DASHI.Example.Identity.identity"
            , declarationBuiltin = Nothing
            , declarationRole = ComputationalFunction
            , declarationUniverses = Vector.empty
            , declarationModuleParameters = Vector.empty
            , declarationType = TermId 2
            , declarationBody = Just (TermId 3)
            , declarationDependencies =
                Set.singleton (CanonicalName "DASHI.Example.Carrier")
            , declarationFeatures =
                Set.singleton StructuralRecursion
            , declarationSource =
                SourceSpan
                  { sourceFile = "DASHI/Example/Identity.agda"
                  , sourceStartLine = 5
                  , sourceEndLine = 6
                  }
            , declarationMapping = Exact
            }
    }

exampleModuleReordered :: ModuleIR
exampleModuleReordered =
  exampleModule
    { moduleTerms =
        foldr
          (uncurry Map.insert)
          Map.empty
          [ (TermId 3, moduleTerms exampleModule Map.! TermId 3)
          , (TermId 1, moduleTerms exampleModule Map.! TermId 1)
          , (TermId 4, moduleTerms exampleModule Map.! TermId 4)
          , (TermId 0, moduleTerms exampleModule Map.! TermId 0)
          , (TermId 2, moduleTerms exampleModule Map.! TermId 2)
          ]
    }
