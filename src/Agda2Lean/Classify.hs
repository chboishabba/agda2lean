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
        max
          (declarationMapping declaration)
          (requiredMode inferredFeatures)
    , classificationFeatures = inferredFeatures
    , classificationReasons = reasons inferredFeatures
    }
  where
    roots =
      declarationType declaration
        : maybe [] pure (declarationBody declaration)
    reachable = reachableTerms (moduleTerms moduleIR) roots
    inferredFeatures =
      declarationFeatures declaration
        <> foldMap termFeatures reachable

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

termReferences :: CoreTerm -> Set TermId
termReferences term =
  case term of
    Var _ -> Set.empty
    Sort _ -> Set.empty
    Pi binder body -> Set.fromList [binderType binder, body]
    Sigma binder body -> Set.fromList [binderType binder, body]
    Lam binder body -> Set.fromList [binderType binder, body]
    App function argument ->
      Set.fromList [function, argumentTerm argument]
    Constructor _ arguments -> argumentReferences arguments
    Eliminator _ arguments -> argumentReferences arguments
    Equality type' left right -> Set.fromList [type', left, right]
    Axiom _ -> Set.empty
    Extension extension ->
      case extension of
        CubicalPrimitive _ terms -> Set.fromList (Vector.toList terms)
        RewritePrimitive _ terms -> Set.fromList (Vector.toList terms)
        CoinductivePrimitive _ terms -> Set.fromList (Vector.toList terms)
        UnsafeUniversePrimitive _ -> Set.empty
  where
    argumentReferences =
      Set.fromList . map argumentTerm . Vector.toList
