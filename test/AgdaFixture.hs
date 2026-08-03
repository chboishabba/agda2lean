{-# LANGUAGE OverloadedStrings #-}

module AgdaFixture
  ( identitySnapshot
  , reconstructSnapshot
  , structuralSnapshot
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
            , agdaDeclarationDefinition =
                AgdaTermDefinition (AgdaLam identityBinder (AgdaVar 0 Vector.empty))
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
            , agdaDeclarationDefinition =
                AgdaTermDefinition
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

structuralSnapshot :: AgdaModule
structuralSnapshot =
  AgdaModule
    { agdaModuleName = CanonicalName "DASHI.Example.Structural"
    , agdaModuleBuiltins =
        Map.fromList
          [ (CanonicalName "Agda.Builtin.Nat.Nat", BuiltinNat)
          , (CanonicalName "Agda.Builtin.Nat.Nat.zero", BuiltinNatZero)
          , (CanonicalName "Agda.Builtin.Nat.Nat.suc", BuiltinNatSuc)
          ]
    , agdaModuleImports = Set.singleton (CanonicalName "Agda.Builtin.Nat")
    , agdaModuleDeclarations =
        Vector.fromList
          [ observationDeclaration
          , predecessorDeclaration
          , oneDeclaration
          , blockedDeclaration
          , observationConstructorDeclaration
          , observationProjectionDeclaration
          ]
    }
  where
    nat = AgdaDef (CanonicalName "Agda.Builtin.Nat.Nat") Vector.empty
    zero = AgdaCon (CanonicalName "Agda.Builtin.Nat.Nat.zero") Vector.empty
    binder =
      AgdaBinder
        { agdaBinderName = "n"
        , agdaBinderType = nat
        , agdaBinderVisibility = Explicit
        , agdaBinderRelevance = Relevant
        }
    observationDeclaration =
      AgdaDeclaration
        { agdaDeclarationName = CanonicalName "DASHI.Example.Structural.Observation"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalData
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType = AgdaSort UZero
        , agdaDeclarationDefinition =
            AgdaRecordDefinition
              AgdaRecordSchema
                { agdaRecordParameters = Vector.empty
                , agdaRecordConstructor =
                    CanonicalName "DASHI.Example.Structural.Observation.constructor"
                , agdaRecordFields =
                    Vector.singleton
                      AgdaRecordField
                        { agdaRecordFieldName =
                            CanonicalName "DASHI.Example.Structural.Observation.value"
                        , agdaRecordFieldType = nat
                        }
                }
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.empty
        , agdaDeclarationSource = SourceSpan "Structural.agda" 1 3
        }
    predecessorDeclaration =
      AgdaDeclaration
        { agdaDeclarationName = CanonicalName "DASHI.Example.Structural.predecessor"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalFunction
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType = AgdaPi binder nat
        , agdaDeclarationDefinition =
            AgdaClauseDefinition
              ( Vector.fromList
                  [ AgdaClause
                      { agdaClauseTelescope = Vector.empty
                      , agdaClausePatterns =
                          Vector.singleton
                            (AgdaPatternBuiltin BuiltinNatZero Vector.empty)
                      , agdaClauseBody = zero
                      }
                  , AgdaClause
                      { agdaClauseTelescope = Vector.singleton binder
                      , agdaClausePatterns =
                          Vector.singleton
                            ( AgdaPatternBuiltin
                                BuiltinNatSuc
                                (Vector.singleton (AgdaPatternVariable 0))
                            )
                      , agdaClauseBody = AgdaVar 0 Vector.empty
                      }
                  ]
              )
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.singleton StructuralRecursion
        , agdaDeclarationSource = SourceSpan "Structural.agda" 5 7
        }
    oneDeclaration =
      AgdaDeclaration
        { agdaDeclarationName = CanonicalName "DASHI.Example.Structural.one"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalFunction
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType = nat
        , agdaDeclarationDefinition =
            AgdaTermDefinition
              ( AgdaCon
                  (CanonicalName "Agda.Builtin.Nat.Nat.suc")
                  (Vector.singleton (AgdaApply Explicit Relevant zero))
              )
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.empty
        , agdaDeclarationSource = SourceSpan "Structural.agda" 8 8
        }
    blockedDeclaration =
      AgdaDeclaration
        { agdaDeclarationName = CanonicalName "DASHI.Example.Structural.dependent"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalFunction
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType = AgdaPi binder nat
        , agdaDeclarationDefinition =
            AgdaBlockedDefinition
              "dependent-pattern"
              "dot/forced patterns require motive reconstruction"
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.empty
        , agdaDeclarationSource = SourceSpan "Structural.agda" 10 11
        }
    observationConstructorDeclaration =
      AgdaDeclaration
        { agdaDeclarationName =
            CanonicalName "DASHI.Example.Structural.Observation.constructor"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalWitness
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType = AgdaDef (CanonicalName "DASHI.Example.Structural.Observation") Vector.empty
        , agdaDeclarationDefinition =
            AgdaConstructorDefinition
              AgdaConstructorSchema
                { agdaConstructorOwner =
                    CanonicalName "DASHI.Example.Structural.Observation"
                }
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.empty
        , agdaDeclarationSource = SourceSpan "Structural.agda" 1 3
        }
    observationProjectionDeclaration =
      AgdaDeclaration
        { agdaDeclarationName =
            CanonicalName "DASHI.Example.Structural.Observation.value"
        , agdaDeclarationBuiltin = Nothing
        , agdaDeclarationRole = ComputationalFunction
        , agdaDeclarationUniverses = Vector.empty
        , agdaDeclarationModuleParameters = Vector.empty
        , agdaDeclarationType =
            AgdaPi
              ( binder
                  { agdaBinderName = "observation"
                  , agdaBinderType =
                      AgdaDef (CanonicalName "DASHI.Example.Structural.Observation") Vector.empty
                  }
              )
              nat
        , agdaDeclarationDefinition =
            AgdaProjectionDefinition
              AgdaProjectionSchema
                { agdaProjectionRecord =
                    CanonicalName "DASHI.Example.Structural.Observation"
                , agdaProjectionField =
                    CanonicalName "DASHI.Example.Structural.Observation.value"
                , agdaProjectionIndex = 1
                }
        , agdaDeclarationAdditionalDependencies = Set.empty
        , agdaDeclarationFeatures = Set.empty
        , agdaDeclarationSource = SourceSpan "Structural.agda" 2 2
        }
