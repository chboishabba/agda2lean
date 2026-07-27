{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.IR
  ( Argument (..)
  , Binder (..)
  , BinderId (..)
  , BuiltinId (..)
  , CanonicalName (..)
  , CoreDeclaration (..)
  , CoreTerm (..)
  , DeclarationRole (..)
  , ExtensionTerm (..)
  , Feature (..)
  , MappingMode (..)
  , ModuleIR (..)
  , Relevance (..)
  , SchemaVersion (..)
  , SourceSpan (..)
  , TermId (..)
  , Universe (..)
  , Visibility (..)
  , currentSchemaVersion
  , termReferences
  , validateModule
  ) where

import Data.List (group, sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Vector (Vector)
import qualified Data.Vector as Vector
import Data.Word (Word16, Word64)
import GHC.Generics (Generic)

newtype SchemaVersion = SchemaVersion {unSchemaVersion :: Word16}
  deriving stock (Eq, Ord, Show, Generic)

currentSchemaVersion :: SchemaVersion
currentSchemaVersion = SchemaVersion 2

newtype CanonicalName = CanonicalName {unCanonicalName :: Text}
  deriving stock (Eq, Ord, Show, Generic)

-- | Language-neutral identities for the small set of cross-language
-- primitives whose target representation is a semantic choice.
data BuiltinId
  = BuiltinNat
  | BuiltinNatZero
  | BuiltinNatSuc
  | BuiltinNatAdd
  | BuiltinNatSub
  | BuiltinNatMul
  | BuiltinNatEq
  | BuiltinNatLt
  | BuiltinBool
  | BuiltinBoolTrue
  | BuiltinBoolFalse
  | BuiltinEquality
  | BuiltinRefl
  | BuiltinLevel
  | BuiltinLevelZero
  | BuiltinLevelSuc
  | BuiltinLevelMax
  | BuiltinProp
  | BuiltinSet
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

newtype BinderId = BinderId {unBinderId :: Word64}
  deriving stock (Eq, Ord, Show, Generic)

newtype TermId = TermId {unTermId :: Word64}
  deriving stock (Eq, Ord, Show, Generic)

data Visibility
  = Explicit
  | Implicit
  | Instance
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

data Relevance
  = Relevant
  | Irrelevant
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

data Universe
  = UZero
  | USuc Universe
  | UMax (Vector Universe)
  | ULevel Text
  | UProp Universe
  | USSet Universe
  deriving stock (Eq, Ord, Show, Generic)

data Binder = Binder
  { binderId :: BinderId
  , binderName :: Text
  , binderType :: TermId
  , binderVisibility :: Visibility
  , binderRelevance :: Relevance
  }
  deriving stock (Eq, Ord, Show, Generic)

data Argument = Argument
  { argumentVisibility :: Visibility
  , argumentRelevance :: Relevance
  , argumentTerm :: TermId
  }
  deriving stock (Eq, Ord, Show, Generic)

data ExtensionTerm
  = CubicalPrimitive Text (Vector TermId)
  | RewritePrimitive CanonicalName (Vector TermId)
  | CoinductivePrimitive Text (Vector TermId)
  | UnsafeUniversePrimitive Text
  deriving stock (Eq, Ord, Show, Generic)

-- | The compact IR is a DAG: every child is referenced through a 'TermId'.
-- This prevents repeated module telescopes and proof subterms from expanding
-- into a serialized tree.
data CoreTerm
  = Var BinderId
  | Sort Universe
  | Pi Binder TermId
  | Sigma Binder TermId
  | Lam Binder TermId
  | App TermId Argument
  | Constructor CanonicalName (Vector Argument)
  | Eliminator CanonicalName (Vector Argument)
  | Equality TermId TermId TermId
  | Axiom CanonicalName
  | Builtin BuiltinId
  | Extension ExtensionTerm
  deriving stock (Eq, Ord, Show, Generic)

data DeclarationRole
  = ComputationalData
  | ComputationalFunction
  | ComputationalWitness
  | LogicalProposition
  | Theorem
  | AxiomDeclaration
  | Certificate
  | Adapter
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

data MappingMode
  = Exact
  | Encoded
  | Reconstruct
  | Quarantined
  | Unsupported
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

data Feature
  = OrdinaryEquality
  | StructuralRecursion
  | WellFoundedRecursion
  | Cubical
  | RewriteRule
  | Coinduction
  | UnsafeUniverse
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)

data SourceSpan = SourceSpan
  { sourceFile :: Text
  , sourceStartLine :: Word64
  , sourceEndLine :: Word64
  }
  deriving stock (Eq, Ord, Show, Generic)

data CoreDeclaration = CoreDeclaration
  { declarationName :: CanonicalName
  , declarationBuiltin :: Maybe BuiltinId
  , declarationRole :: DeclarationRole
  , declarationUniverses :: Vector Text
  , declarationModuleParameters :: Vector Binder
  , declarationType :: TermId
  , declarationBody :: Maybe TermId
  , declarationDependencies :: Set CanonicalName
  , declarationFeatures :: Set Feature
  , declarationSource :: SourceSpan
  , declarationMapping :: MappingMode
  }
  deriving stock (Eq, Show, Generic)

data ModuleIR = ModuleIR
  { moduleSchemaVersion :: SchemaVersion
  , moduleName :: CanonicalName
  , moduleImports :: Set CanonicalName
  , moduleTerms :: Map TermId CoreTerm
  , moduleDeclarations :: Vector CoreDeclaration
  }
  deriving stock (Eq, Show, Generic)

validateModule :: ModuleIR -> Either (Vector Text) ModuleIR
validateModule ir
  | Vector.null errors = Right ir
  | otherwise = Left errors
  where
    errors =
      Vector.fromList
        ( schemaErrors
            <> nameErrors
            <> duplicateErrors
            <> concatMap validateTerm (Map.toAscList (moduleTerms ir))
            <> concatMap validateDeclaration (Vector.toList (moduleDeclarations ir))
        )

    schemaErrors =
      [ "unsupported schema version: "
          <> Text.pack (show (unSchemaVersion (moduleSchemaVersion ir)))
      | moduleSchemaVersion ir /= currentSchemaVersion
      ]

    nameErrors =
      [ "module name must be fully qualified and non-empty"
      | not (validCanonicalName (moduleName ir))
      ]

    declarationNames =
      sort
        (map declarationName (Vector.toList (moduleDeclarations ir)))

    duplicateErrors =
      [ "duplicate declaration: " <> unCanonicalName duplicateName
      | duplicateGroup@(duplicateName : _) <- group declarationNames
      , length duplicateGroup > 1
      ]

    termExists termId = Map.member termId (moduleTerms ir)

    validateTerm (owner, term) =
      [ "term "
          <> showText owner
          <> " references missing term "
          <> showText referenced
      | referenced <- Set.toAscList (termReferences term)
      , not (termExists referenced)
      ]

    validateDeclaration declaration =
      [ "invalid declaration name: "
          <> unCanonicalName (declarationName declaration)
      | not (validCanonicalName (declarationName declaration))
      ]
        <> [ "declaration "
               <> unCanonicalName (declarationName declaration)
               <> " is outside module namespace "
               <> unCanonicalName (moduleName ir)
           | not (declarationBelongsToModule declaration)
           ]
        <> [ "missing type term for "
               <> unCanonicalName (declarationName declaration)
           | not (termExists (declarationType declaration))
           ]
        <> [ "missing body term for "
               <> unCanonicalName (declarationName declaration)
           | Just body <- [declarationBody declaration]
           , not (termExists body)
           ]
        <> [ "module parameter "
               <> binderName binder
               <> " of "
               <> unCanonicalName (declarationName declaration)
               <> " references missing type term "
               <> showText (binderType binder)
           | binder <- Vector.toList (declarationModuleParameters declaration)
           , not (termExists (binderType binder))
           ]
        <> [ "invalid source span for "
               <> unCanonicalName (declarationName declaration)
           | let span' = declarationSource declaration
           , sourceStartLine span' == 0
               || sourceEndLine span' < sourceStartLine span'
           ]
        <> [ "unsupported declarations must not carry a proof body: "
               <> unCanonicalName (declarationName declaration)
           | declarationMapping declaration == Unsupported
           , declarationBody declaration /= Nothing
           ]

    declarationBelongsToModule declaration =
      let modulePrefix = unCanonicalName (moduleName ir) <> "."
       in modulePrefix
            `Text.isPrefixOf` unCanonicalName (declarationName declaration)

validCanonicalName :: CanonicalName -> Bool
validCanonicalName (CanonicalName name) =
  not (Text.null name)
    && not (Text.isPrefixOf "." name)
    && not (Text.isSuffixOf "." name)
    && not (".." `Text.isInfixOf` name)

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
    Builtin _ -> Set.empty
    Extension extension ->
      case extension of
        CubicalPrimitive _ terms -> Set.fromList (Vector.toList terms)
        RewritePrimitive _ terms -> Set.fromList (Vector.toList terms)
        CoinductivePrimitive _ terms -> Set.fromList (Vector.toList terms)
        UnsafeUniversePrimitive _ -> Set.empty
  where
    argumentReferences =
      Set.fromList . map argumentTerm . Vector.toList

showText :: Show a => a -> Text
showText = Text.pack . show
