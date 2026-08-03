{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Classify
  ( Classification (..)
  , classifyDeclaration
  , classifyModule
  ) where

import Agda2Lean.IR
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Vector as Vector

data Classification = Classification
  { classificationMode :: MappingMode
  , classificationFeatures :: Set Feature
  , classificationReasons :: Vector.Vector Text
  }
  deriving stock (Eq, Show)

classifyModule :: ModuleIR -> ModuleIR
classifyModule moduleIR =
  moduleIR
    { moduleDeclarations =
        Vector.map
          applyClassification
          (moduleDeclarations moduleIR)
    }
  where
    applyClassification declaration =
      let classification = classifyDeclaration moduleIR declaration
       in declaration
            { declarationMapping = classificationMode classification
            , declarationFeatures = classificationFeatures classification
            }

classifyDeclaration :: ModuleIR -> CoreDeclaration -> Classification
classifyDeclaration moduleIR declaration =
  Classification
    { classificationMode =
        stricterMode
          (declarationMapping declaration)
          ( stricterMode
              (requiredMode inferredFeatures)
              (definitionMode (declarationDefinition declaration))
          )
    , classificationFeatures = inferredFeatures
    , classificationReasons =
        reasons inferredFeatures
          <> definitionReasons (declarationDefinition declaration)
    }
  where
    roots =
      declarationType declaration
        : ( definitionRoots (declarationDefinition declaration)
              <> map
                binderType
                (Vector.toList (declarationModuleParameters declaration))
          )
    reachable = reachableTerms (moduleTerms moduleIR) roots
    inferredFeatures =
      declarationFeatures declaration
        <> foldMap termFeatures reachable

definitionRoots :: DeclarationDefinition -> [TermId]
definitionRoots definition =
  case definition of
    TermDefinition body -> [body]
    ClauseDefinition clauses ->
      concat
        [ clauseBody clause
            : map binderType (Vector.toList (clauseTelescope clause))
        | clause <- Vector.toList clauses
        ]
    DataDefinition _ -> []
    RecordDefinition schema ->
      map binderType (Vector.toList (recordParameters schema))
        <> map (binderType . recordFieldBinder) (Vector.toList (recordFields schema))
    ConstructorDefinition _ -> []
    ProjectionDefinition _ -> []
    AxiomDefinition -> []
    BlockedDefinition _ -> []

definitionMode :: DeclarationDefinition -> MappingMode
definitionMode definition =
  case definition of
    BlockedDefinition _ -> Unsupported
    _ -> Exact

definitionReasons :: DeclarationDefinition -> Vector.Vector Text
definitionReasons definition =
  case definition of
    BlockedDefinition obligation ->
      Vector.singleton
        ("definition is outside the portable fragment: " <> renderObligation obligation)
    _ -> Vector.empty
  where
    renderObligation obligation =
      case obligation of
        UnsupportedDependentPattern message -> message
        UnsupportedClauseBody message -> message
        UnsupportedDefinitionKind message -> message

stricterMode :: MappingMode -> MappingMode -> MappingMode
stricterMode left right
  | mappingSeverity left >= mappingSeverity right = left
  | otherwise = right

-- Keep policy independent of constructor order and therefore of the CBOR tag
-- order used by the codec.
mappingSeverity :: MappingMode -> Int
mappingSeverity mode =
  case mode of
    Exact -> 0
    Encoded -> 1
    Reconstruct -> 2
    Quarantined -> 3
    Unsupported -> 4

requiredMode :: Set Feature -> MappingMode
requiredMode features
  | UnsafeUniverse `Set.member` features = Unsupported
  | Cubical `Set.member` features = Quarantined
  | Coinduction `Set.member` features = Reconstruct
  | RewriteRule `Set.member` features = Reconstruct
  | WellFoundedRecursion `Set.member` features = Encoded
  | otherwise = Exact

reasons :: Set Feature -> Vector.Vector Text
reasons features =
  Vector.fromList
    ( [ "unsafe universe behaviour cannot enter the portable core"
      | UnsafeUniverse `Set.member` features
      ]
        <> [ "Cubical primitives require an explicit lowering or quarantine"
           | Cubical `Set.member` features
           ]
        <> [ "coinduction requires native reconstruction"
           | Coinduction `Set.member` features
           ]
        <> [ "rewrite rules must become checked equalities or native reconstruction"
           | RewriteRule `Set.member` features
           ]
        <> [ "well-founded recursion requires a termination adapter"
           | WellFoundedRecursion `Set.member` features
           ]
    )

reachableTerms :: Map.Map TermId CoreTerm -> [TermId] -> [CoreTerm]
reachableTerms table = go Set.empty
  where
    go _ [] = []
    go visited (termId : pending)
      | termId `Set.member` visited = go visited pending
      | otherwise =
          case Map.lookup termId table of
            Nothing -> go (Set.insert termId visited) pending
            Just term ->
              term
                : go
                  (Set.insert termId visited)
                  (Set.toList (termReferences term) <> pending)

termFeatures :: CoreTerm -> Set Feature
termFeatures term =
  case term of
    Extension extension ->
      Set.singleton
        (case extension of
           CubicalPrimitive {} -> Cubical
           RewritePrimitive {} -> RewriteRule
           CoinductivePrimitive {} -> Coinduction
           UnsafeUniversePrimitive {} -> UnsafeUniverse
        )
    _ -> Set.empty
