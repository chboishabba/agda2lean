{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import qualified Agda.Syntax.Common as Agda
import Agda.Syntax.Common.Pretty (Pretty, prettyShow)
import qualified Agda.Syntax.Internal as Agda
import qualified Agda.Syntax.Internal.Elim as Agda
import qualified Agda.Syntax.Literal as Agda
import Agda.Syntax.Position
import Agda.Syntax.TopLevelModuleName (TopLevelModuleName)
import qualified Agda.TypeChecking.Monad.Base as Agda
import qualified Agda.TypeChecking.Primitive as AgdaPrimitive
import qualified Agda.Syntax.Builtin as AgdaBuiltin
import qualified Agda.Utils.Maybe.Strict as Strict
import Agda.Compiler.Backend hiding (canonicalName)
import Agda.Compiler.Common (compileDir, curIF)
import Agda.Interaction.Options (ArgDescr (..), OptDescr (..))
import Agda.Main (runAgda)
import Agda.Utils.FileName (filePath)
import Agda2Lean.Agda.Extract (extractModule, renderExtractionError)
import qualified Agda2Lean.Agda.Snapshot as Snapshot
import Agda2Lean.Codec (encodeModule)
import qualified Agda2Lean.IR as Core
import Control.DeepSeq (NFData)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as ByteString
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Vector as Vector
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeDirectory)

data Options = Options
  { optionEnabled :: Bool
  }
  deriving stock (Generic)

instance NFData Options

data ModuleEnvironment = ModuleEnvironment
  { environmentName :: CanonicalModuleName
  , environmentBuiltins :: Map.Map Core.CanonicalName Core.BuiltinId
  }

newtype CanonicalModuleName = CanonicalModuleName
  { unCanonicalModuleName :: Core.CanonicalName
  }

defaultOptions :: Options
defaultOptions = Options False

backend :: Backend
backend =
  Backend
    Backend'
      { backendName = "LeanIR"
      , backendVersion = Just "0.1"
      , options = defaultOptions
      , commandLineFlags =
          [ Option
              []
              ["lean-ir"]
              (NoArg (\options' -> pure options' {optionEnabled = True}))
              "extract typechecked declarations to canonical agda2lean CBOR"
          ]
      , isEnabled = optionEnabled
      , preCompile = pure
      , postCompile = \_ _ _ -> pure ()
      , preModule = preModule'
      , postModule = postModule'
      , compileDef = compileDefinition
      , scopeCheckingSuffices = False
      , mayEraseType = const (pure False)
      , backendInteractTop = Nothing
      , backendInteractHole = Nothing
      }

main :: IO ()
main = runAgda [backend]

preModule' ::
  Options ->
  IsMain ->
  TopLevelModuleName ->
  Maybe FilePath ->
  TCM (Recompile ModuleEnvironment ())
preModule' _ _ moduleName' _ =
  do
    builtins <- activeBuiltinBindings
    pure
      ( Recompile
          (ModuleEnvironment (CanonicalModuleName (canonicalName moduleName')) builtins)
      )

postModule' ::
  Options ->
  ModuleEnvironment ->
  IsMain ->
  TopLevelModuleName ->
  [Snapshot.AgdaDeclaration] ->
  TCM ()
postModule' _ ModuleEnvironment {..} _ moduleName' declarations = do
  interface <- curIF
  outputDirectory <- compileDir
  let imported =
        Set.fromList
          [ canonicalName importedName
          | (importedName, _) <- iImportedModules interface
          ]
      snapshot =
        Snapshot.AgdaModule
          { Snapshot.agdaModuleName = unCanonicalModuleName environmentName
          , Snapshot.agdaModuleBuiltins = environmentBuiltins
          , Snapshot.agdaModuleImports = imported
          , Snapshot.agdaModuleDeclarations = Vector.fromList declarations
          }
      relativePath =
        foldr
          (</>)
          "module.a2l.cbor"
          (map Text.unpack (Text.splitOn "." (Core.unCanonicalName (canonicalName moduleName'))))
      outputPath = outputDirectory </> relativePath
  case extractModule snapshot of
    Left issue ->
      liftIO
        (ioError (userError (Text.unpack (renderExtractionError issue))))
    Right moduleIR ->
      liftIO $ do
        createDirectoryIfMissing True (takeDirectory outputPath)
        ByteString.writeFile outputPath (encodeModule moduleIR)
        Text.putStrLn
          ( "LeanIR "
              <> Core.unCanonicalName (Core.moduleName moduleIR)
              <> " -> "
              <> Text.pack outputPath
          )

compileDefinition ::
  Options ->
  ModuleEnvironment ->
  IsMain ->
  Agda.Definition ->
  TCM Snapshot.AgdaDeclaration
compileDefinition _ ModuleEnvironment {..} _ definition =
  let extractedType = snapshotType (Agda.defType definition)
      extractedDefinition
        | Core.UnsafeUniverse `Set.member` termFeaturesSnapshot extractedType =
            Snapshot.AgdaBlockedDefinition
              "definition-kind"
              ( Core.unCanonicalName (canonicalName (Agda.defName definition))
                  <> ": declaration type contains an unsafe/unsolved universe term"
              )
        | otherwise =
            snapshotDefinition
              environmentBuiltins
              (canonicalName (Agda.defName definition))
              (Agda.theDef definition)
   in pure
    Snapshot.AgdaDeclaration
      { Snapshot.agdaDeclarationName = canonicalName (Agda.defName definition)
      , Snapshot.agdaDeclarationBuiltin =
          Map.lookup (canonicalName (Agda.defName definition)) environmentBuiltins
      , Snapshot.agdaDeclarationRole = declarationRole (Agda.theDef definition)
      , Snapshot.agdaDeclarationUniverses =
          Vector.fromList (Set.toAscList (universeNames extractedType))
      -- Agda's defType is already lifted over parameterised modules. Keeping
      -- this metadata empty avoids duplicating the telescope in the IR.
      , Snapshot.agdaDeclarationModuleParameters = Vector.empty
      , Snapshot.agdaDeclarationType = extractedType
      , Snapshot.agdaDeclarationDefinition = extractedDefinition
      , Snapshot.agdaDeclarationAdditionalDependencies =
          definitionBodyDependencies definition
      , Snapshot.agdaDeclarationFeatures = definitionFeatures definition
      , Snapshot.agdaDeclarationSource = sourceSpan (Agda.defName definition)
      }

snapshotDefinition ::
  Map.Map Core.CanonicalName Core.BuiltinId ->
  Core.CanonicalName ->
  Agda.Defn ->
  Snapshot.AgdaDeclarationDefinition
snapshotDefinition builtins owner = \case
  Agda.Axiom {} -> Snapshot.AgdaAxiomDefinition
  Agda.Datatype
    { Agda.dataPars = parameterCount
    , Agda.dataCons = constructors
    , Agda.dataPathCons = pathConstructors
    }
      | null pathConstructors ->
          Snapshot.AgdaDataDefinition
            Snapshot.AgdaDataSchema
              { Snapshot.agdaDataParameterCount = fromIntegral parameterCount
              , Snapshot.agdaDataConstructors =
                  Vector.fromList (map canonicalName constructors)
              }
      | otherwise ->
          blocked
            "dependent-pattern"
            "higher-inductive path constructors are outside the portable fragment"
  Agda.Record
    { Agda.recPars = parameterCount
    , Agda.recConHead = constructor
    , Agda.recFields = fields
    , Agda.recTel = telescope
    , Agda.recInduction = induction
    }
      | induction == Just Agda.CoInductive ->
          blocked
            "definition-kind"
            "coinductive records are outside the portable fragment"
      | otherwise ->
          let binders = snapshotTelescope telescope
              (parameters, fieldBinders) = splitAt parameterCount binders
              fieldNames = map (canonicalName . Agda.unDom) fields
           in if length fieldNames /= length fieldBinders
                then
                  blocked
                    "definition-kind"
                    ( "record telescope/field mismatch: "
                        <> Text.pack (show (length fieldBinders))
                        <> " field binders for "
                        <> Text.pack (show (length fieldNames))
                        <> " names"
                    )
                else
                  if any
                    ( Set.member Core.UnsafeUniverse
                        . termFeaturesSnapshot
                        . Snapshot.agdaBinderType
                    )
                    binders
                    then
                      blocked
                        "definition-kind"
                        "record telescope contains an unsafe/unsolved universe term"
                    else
                      Snapshot.AgdaRecordDefinition
                        Snapshot.AgdaRecordSchema
                          { Snapshot.agdaRecordParameters = Vector.fromList parameters
                          , Snapshot.agdaRecordConstructor =
                              canonicalName (Agda.conName constructor)
                          , Snapshot.agdaRecordFields =
                              Vector.fromList
                                ( zipWith
                                    (\name binder ->
                                       Snapshot.AgdaRecordField
                                         { Snapshot.agdaRecordFieldName = name
                                         , Snapshot.agdaRecordFieldType =
                                             Snapshot.agdaBinderType binder
                                         }
                                    )
                                    fieldNames
                                    fieldBinders
                                )
                          }
  Agda.Constructor {Agda.conData = datatype} ->
    Snapshot.AgdaConstructorDefinition
      Snapshot.AgdaConstructorSchema
        { Snapshot.agdaConstructorOwner = canonicalName datatype
        }
  Agda.Function {Agda.funProjection = Right projection}
    | Just record <- Agda.projProper projection ->
        Snapshot.AgdaProjectionDefinition
          Snapshot.AgdaProjectionSchema
            { Snapshot.agdaProjectionRecord = canonicalName record
            , Snapshot.agdaProjectionField = owner
            , Snapshot.agdaProjectionIndex =
                fromIntegral (max 0 (Agda.projIndex projection))
            }
  Agda.Function {Agda.funClauses = clauses} ->
    snapshotClauses builtins owner clauses
  Agda.Primitive {Agda.primClauses = clauses}
    | not (null clauses) -> snapshotClauses builtins owner clauses
    | otherwise ->
        blocked
          "definition-kind"
          "opaque Agda primitive has no portable clause body"
  Agda.PrimitiveSort {} ->
    blocked
      "definition-kind"
      "Agda primitive sorts require a platform mapping"
  Agda.AbstractDefn inner -> snapshotDefinition builtins owner inner
  other ->
    blocked
      "definition-kind"
      ("unsupported Agda definition: " <> Text.pack (prettyShow other))
  where
    blocked code detail = Snapshot.AgdaBlockedDefinition code detail

snapshotClauses ::
  Map.Map Core.CanonicalName Core.BuiltinId ->
  Core.CanonicalName ->
  [Agda.Clause] ->
  Snapshot.AgdaDeclarationDefinition
snapshotClauses builtins owner clauses =
  case traverse (snapshotClause builtins owner) clauses of
    Left (code, detail) -> Snapshot.AgdaBlockedDefinition code detail
    Right [] ->
      Snapshot.AgdaBlockedDefinition
        "clause-body"
        (Core.unCanonicalName owner <> ": definition has no executable clauses")
    Right portable
      | any clauseHasUnsafeUniverse portable ->
          Snapshot.AgdaBlockedDefinition
            "clause-body"
            ( Core.unCanonicalName owner
                <> ": clause body contains an unsolved/internal universe term"
            )
    Right [clause]
      | Vector.null (Snapshot.agdaClauseTelescope clause)
      , Vector.null (Snapshot.agdaClausePatterns clause) ->
          Snapshot.AgdaTermDefinition (Snapshot.agdaClauseBody clause)
    Right portable ->
      Snapshot.AgdaClauseDefinition (Vector.fromList portable)
  where
    clauseHasUnsafeUniverse clause =
      Core.UnsafeUniverse
        `Set.member` ( termFeaturesSnapshot (Snapshot.agdaClauseBody clause)
                        <> foldMap
                          (termFeaturesSnapshot . Snapshot.agdaBinderType)
                          (Snapshot.agdaClauseTelescope clause)
                    )

termFeaturesSnapshot :: Snapshot.AgdaTerm -> Set.Set Core.Feature
termFeaturesSnapshot = \case
  Snapshot.AgdaVar _ eliminations -> foldMap eliminationFeaturesSnapshot eliminations
  Snapshot.AgdaLam binder body ->
    termFeaturesSnapshot (Snapshot.agdaBinderType binder) <> termFeaturesSnapshot body
  Snapshot.AgdaDef _ eliminations -> foldMap eliminationFeaturesSnapshot eliminations
  Snapshot.AgdaCon _ eliminations -> foldMap eliminationFeaturesSnapshot eliminations
  Snapshot.AgdaPi binder body ->
    termFeaturesSnapshot (Snapshot.agdaBinderType binder) <> termFeaturesSnapshot body
  Snapshot.AgdaSigma binder body ->
    termFeaturesSnapshot (Snapshot.agdaBinderType binder) <> termFeaturesSnapshot body
  Snapshot.AgdaSort _ -> Set.empty
  Snapshot.AgdaLevel _ -> Set.empty
  Snapshot.AgdaEquality type' left right ->
    Set.insert
      Core.OrdinaryEquality
      (termFeaturesSnapshot type' <> termFeaturesSnapshot left <> termFeaturesSnapshot right)
  Snapshot.AgdaLiteral _ _ -> Set.empty
  Snapshot.AgdaUnsupported feature _ arguments ->
    Set.insert feature (foldMap termFeaturesSnapshot arguments)

eliminationFeaturesSnapshot :: Snapshot.AgdaElimination -> Set.Set Core.Feature
eliminationFeaturesSnapshot = \case
  Snapshot.AgdaApply _ _ term -> termFeaturesSnapshot term
  Snapshot.AgdaProject _ -> Set.empty
  Snapshot.AgdaIntervalApply left right interval ->
    Set.insert
      Core.Cubical
      ( termFeaturesSnapshot left
          <> termFeaturesSnapshot right
          <> termFeaturesSnapshot interval
      )

snapshotClause ::
  Map.Map Core.CanonicalName Core.BuiltinId ->
  Core.CanonicalName ->
  Agda.Clause ->
  Either (Text.Text, Text.Text) Snapshot.AgdaClause
snapshotClause builtins owner clause = do
  body <-
    maybe
      ( Left
          ( "clause-body"
          , Core.unCanonicalName owner <> ": absurd clauses are not yet portable"
          )
      )
      (Right . snapshotTerm)
      (Agda.clauseBody clause)
  patterns <-
    traverse
      (snapshotPattern builtins . Agda.namedArg)
      (filter explicitNamedArgument (Agda.namedClausePats clause))
  pure
    Snapshot.AgdaClause
      { Snapshot.agdaClauseTelescope =
          Vector.fromList (snapshotTelescope (Agda.clauseTel clause))
      , Snapshot.agdaClausePatterns = Vector.fromList patterns
      , Snapshot.agdaClauseBody = body
      }

snapshotPattern ::
  Map.Map Core.CanonicalName Core.BuiltinId ->
  Agda.DeBruijnPattern ->
  Either (Text.Text, Text.Text) Snapshot.AgdaPattern
snapshotPattern builtins = \case
  Agda.VarP info variable
    | Agda.patOrigin info == Agda.PatOWild ->
        Right Snapshot.AgdaPatternWildcard
    | Agda.patOrigin info == Agda.PatOAbsurd ->
        Left ("dependent-pattern", "absurd patterns require motive reconstruction")
    | otherwise ->
        Right (Snapshot.AgdaPatternVariable (Agda.dbPatVarIndex variable))
  Agda.ConP constructor _ arguments -> do
    children <-
      traverse
        (snapshotPattern builtins . Agda.namedArg)
        (filter explicitNamedArgument arguments)
    let name = canonicalName (Agda.conName constructor)
    pure
      ( case Map.lookup name builtins of
          Just builtin -> Snapshot.AgdaPatternBuiltin builtin (Vector.fromList children)
          Nothing -> Snapshot.AgdaPatternConstructor name (Vector.fromList children)
      )
  Agda.LitP _ literal -> do
    (kind, value) <- snapshotPatternLiteral literal
    Right (Snapshot.AgdaPatternLiteral kind value)
  Agda.DotP {} ->
    Left ("dependent-pattern", "dot/forced patterns require motive reconstruction")
  Agda.ProjP {} ->
    Left ("dependent-pattern", "projection copatterns are outside the portable fragment")
  Agda.IApplyP {} ->
    Left ("dependent-pattern", "cubical interval patterns are outside the portable fragment")
  Agda.DefP {} ->
    Left ("dependent-pattern", "higher-inductive definition patterns are outside the portable fragment")

explicitNamedArgument :: Agda.NamedArg a -> Bool
explicitNamedArgument argument =
  Agda.getHiding (Agda.getArgInfo argument) == Agda.NotHidden

snapshotTelescope :: Agda.Telescope -> [Snapshot.AgdaBinder]
snapshotTelescope = \case
  Agda.EmptyTel -> []
  Agda.ExtendTel domain abstraction ->
    snapshotDomain domain (Agda.absName abstraction)
      : snapshotTelescope (Agda.unAbs abstraction)

snapshotPatternLiteral ::
  Agda.Literal ->
  Either (Text.Text, Text.Text) (Text.Text, Text.Text)
snapshotPatternLiteral = \case
  Agda.LitNat value -> Right ("nat", Text.pack (show value))
  Agda.LitWord64 value -> Right ("nat", Text.pack (show value))
  Agda.LitString value -> Right ("string", value)
  Agda.LitChar value -> Right ("char", Text.singleton value)
  Agda.LitFloat _ ->
    Left ("dependent-pattern", "floating-point literal patterns are not portable to Lean")
  Agda.LitQName _ ->
    Left ("dependent-pattern", "quoted-name literal patterns require reflection support")
  Agda.LitMeta _ _ ->
    Left ("dependent-pattern", "metavariable literal patterns are not portable")

activeBuiltinBindings :: TCM (Map.Map Core.CanonicalName Core.BuiltinId)
activeBuiltinBindings =
  Map.fromList . mapMaybe id <$> mapM resolve builtinPairs
  where
    resolve (builtin, target) = do
      name <- AgdaPrimitive.getBuiltinName builtin
      pure ((\resolved -> (canonicalName resolved, target)) <$> name)

    builtinPairs =
      [ (AgdaBuiltin.builtinNat, Core.BuiltinNat)
      , (AgdaBuiltin.builtinZero, Core.BuiltinNatZero)
      , (AgdaBuiltin.builtinSuc, Core.BuiltinNatSuc)
      , (AgdaBuiltin.builtinNatPlus, Core.BuiltinNatAdd)
      , (AgdaBuiltin.builtinNatMinus, Core.BuiltinNatSub)
      , (AgdaBuiltin.builtinNatTimes, Core.BuiltinNatMul)
      , (AgdaBuiltin.builtinNatEquals, Core.BuiltinNatEq)
      , (AgdaBuiltin.builtinNatLess, Core.BuiltinNatLt)
      , (AgdaBuiltin.builtinBool, Core.BuiltinBool)
      , (AgdaBuiltin.builtinTrue, Core.BuiltinBoolTrue)
      , (AgdaBuiltin.builtinFalse, Core.BuiltinBoolFalse)
      , (AgdaBuiltin.builtinList, Core.BuiltinList)
      , (AgdaBuiltin.builtinNil, Core.BuiltinListNil)
      , (AgdaBuiltin.builtinCons, Core.BuiltinListCons)
      , (AgdaBuiltin.builtinEquality, Core.BuiltinEquality)
      , (AgdaBuiltin.builtinRefl, Core.BuiltinRefl)
      , (AgdaBuiltin.builtinLevel, Core.BuiltinLevel)
      , (AgdaBuiltin.builtinLevelZero, Core.BuiltinLevelZero)
      , (AgdaBuiltin.builtinLevelSuc, Core.BuiltinLevelSuc)
      , (AgdaBuiltin.builtinLevelMax, Core.BuiltinLevelMax)
      , (AgdaBuiltin.builtinProp, Core.BuiltinProp)
      , (AgdaBuiltin.builtinSet, Core.BuiltinSet)
      ]

snapshotType :: Agda.Type -> Snapshot.AgdaTerm
snapshotType = snapshotTerm . Agda.unEl

snapshotTerm :: Agda.Term -> Snapshot.AgdaTerm
snapshotTerm = \case
  Agda.Var index eliminations ->
    Snapshot.AgdaVar index (Vector.fromList (map snapshotElimination eliminations))
  Agda.Lam argumentInfo abstraction ->
    Snapshot.AgdaLam
      ( Snapshot.AgdaBinder
          { Snapshot.agdaBinderName = Text.pack (Agda.argNameToString (Agda.absName abstraction))
          , Snapshot.agdaBinderType =
              Snapshot.AgdaUnsupported
                Core.UnsafeUniverse
                "Agda internal lambda has no domain annotation"
                Vector.empty
          , Snapshot.agdaBinderVisibility = visibility argumentInfo
          , Snapshot.agdaBinderRelevance = relevance argumentInfo
          }
      )
      (snapshotTerm (Agda.unAbs abstraction))
  Agda.Lit literal -> snapshotLiteral literal
  Agda.Def name eliminations ->
    Snapshot.AgdaDef
      (canonicalName name)
      (Vector.fromList (map snapshotElimination eliminations))
  Agda.Con head' _ eliminations ->
    Snapshot.AgdaCon
      (canonicalName (Agda.conName head'))
      (Vector.fromList (map snapshotElimination eliminations))
  Agda.Pi domain codomain ->
    Snapshot.AgdaPi
      (snapshotDomain domain (Agda.absName codomain))
      (snapshotType (Agda.unAbs codomain))
  Agda.Sort sort' -> Snapshot.AgdaSort (snapshotSort sort')
  Agda.Level level -> snapshotFirstClassLevel level
  Agda.MetaV meta eliminations ->
    Snapshot.AgdaUnsupported
      Core.UnsafeUniverse
      ("unsolved Agda metavariable: " <> Text.pack (prettyShow meta))
      (Vector.fromList (map eliminationTerm eliminations))
  Agda.DontCare term -> snapshotTerm term
  Agda.Dummy kind eliminations ->
    Snapshot.AgdaUnsupported
      Core.UnsafeUniverse
      ("Agda internal dummy: " <> dummyDescription kind)
      ( Vector.fromList
          ( dummyTerms kind
              <> map eliminationTerm eliminations
          )
      )

dummyDescription :: Agda.DummyTermKind -> Text.Text
dummyDescription = \case
  Agda.DummyNamed label -> Text.pack label
  Agda.DummyBrave term -> "brave term: " <> Text.pack (prettyShow term)

dummyTerms :: Agda.DummyTermKind -> [Snapshot.AgdaTerm]
dummyTerms = \case
  Agda.DummyNamed _ -> []
  Agda.DummyBrave term -> [snapshotTerm term]

snapshotDomain :: Agda.Dom Agda.Type -> Agda.ArgName -> Snapshot.AgdaBinder
snapshotDomain domain suggestedName =
  Snapshot.AgdaBinder
    { Snapshot.agdaBinderName =
        maybe
          (Text.pack (Agda.argNameToString suggestedName))
          (Text.pack . prettyShow)
          (Agda.domName domain)
    , Snapshot.agdaBinderType = snapshotType (Agda.unDom domain)
    , Snapshot.agdaBinderVisibility = visibility (Agda.domInfo domain)
    , Snapshot.agdaBinderRelevance = relevance (Agda.domInfo domain)
    }

snapshotElimination :: Agda.Elim -> Snapshot.AgdaElimination
snapshotElimination = \case
  Agda.Apply argument ->
    Snapshot.AgdaApply
      (visibility (Agda.getArgInfo argument))
      (relevance (Agda.getArgInfo argument))
      (snapshotTerm (Agda.unArg argument))
  Agda.Proj _ name -> Snapshot.AgdaProject (canonicalName name)
  Agda.IApply left right interval ->
    Snapshot.AgdaIntervalApply
      (snapshotTerm left)
      (snapshotTerm right)
      (snapshotTerm interval)

eliminationTerm :: Agda.Elim -> Snapshot.AgdaTerm
eliminationTerm = \case
  Agda.Apply argument -> snapshotTerm (Agda.unArg argument)
  Agda.Proj _ name -> Snapshot.AgdaDef (canonicalName name) Vector.empty
  Agda.IApply _ _ interval -> snapshotTerm interval

snapshotLiteral :: Agda.Literal -> Snapshot.AgdaTerm
snapshotLiteral = \case
  Agda.LitNat value -> literal "nat" value
  Agda.LitWord64 value -> literal "nat" value
  Agda.LitFloat value -> literal "float" value
  Agda.LitString value -> Snapshot.AgdaLiteral "string" value
  Agda.LitChar value -> Snapshot.AgdaLiteral "char" (Text.singleton value)
  Agda.LitQName value -> Snapshot.AgdaDef (canonicalName value) Vector.empty
  Agda.LitMeta _ value ->
    Snapshot.AgdaUnsupported
      Core.UnsafeUniverse
      ("quoted metavariable: " <> Text.pack (prettyShow value))
      Vector.empty
  where
    literal kind value = Snapshot.AgdaLiteral kind (Text.pack (show value))

snapshotSort :: Agda.Sort -> Core.Universe
snapshotSort = \case
  Agda.Type level -> snapshotLevel level
  Agda.Prop level -> Core.UProp (snapshotLevel level)
  Agda.SSet level -> Core.USSet (snapshotLevel level)
  sort' -> Core.ULevel ("agda-sort-" <> Text.pack (prettyShow sort'))

snapshotLevel :: Agda.Level -> Core.Universe
snapshotLevel (Agda.Max closed atoms) =
  maximumUniverse
    (iterateSuccessor closed Core.UZero : map snapshotPlus atoms)
  where
    snapshotPlus (Agda.Plus offset atom) =
      iterateSuccessor
        offset
        (Core.ULevel (Text.pack (prettyShow atom)))

maximumUniverse :: [Core.Universe] -> Core.Universe
maximumUniverse universes =
  case filter (/= Core.UZero) universes of
    [] -> Core.UZero
    [universe] -> universe
    several -> Core.UMax (Vector.fromList several)

iterateSuccessor :: Integer -> Core.Universe -> Core.Universe
iterateSuccessor count universe
  | count <= 0 = universe
  | otherwise = iterateSuccessor (count - 1) (Core.USuc universe)

snapshotFirstClassLevel :: Agda.Level -> Snapshot.AgdaTerm
snapshotFirstClassLevel level@(Agda.Max closed atoms) =
  case traverse snapshotLevelAtom atoms of
    Nothing ->
      Snapshot.AgdaUnsupported
        Core.UnsafeUniverse
        ("non-variable first-class Agda level: " <> Text.pack (prettyShow level))
        ( Vector.fromList
            [ snapshotTerm atom
            | Agda.Plus _ atom <- atoms
            ]
        )
    Just variables ->
      Snapshot.AgdaLevel
        (maximumLevelExpr (iterateLevelSuccessor closed Snapshot.AgdaLevelZero : variables))
  where
    snapshotLevelAtom (Agda.Plus offset atom) =
      case atom of
        Agda.Var index [] ->
          Just
            ( iterateLevelSuccessor
                offset
                (Snapshot.AgdaLevelVariable index)
            )
        _ -> Nothing

maximumLevelExpr :: [Snapshot.AgdaLevelExpr] -> Snapshot.AgdaLevelExpr
maximumLevelExpr levels =
  case filter (/= Snapshot.AgdaLevelZero) levels of
    [] -> Snapshot.AgdaLevelZero
    [level] -> level
    several -> Snapshot.AgdaLevelMaximum (Vector.fromList several)

iterateLevelSuccessor :: Integer -> Snapshot.AgdaLevelExpr -> Snapshot.AgdaLevelExpr
iterateLevelSuccessor count level
  | count <= 0 = level
  | otherwise =
      iterateLevelSuccessor (count - 1) (Snapshot.AgdaLevelSuccessor level)

visibility :: Agda.ArgInfo -> Core.Visibility
visibility info =
  case Agda.getHiding info of
    Agda.NotHidden -> Core.Explicit
    Agda.Hidden -> Core.Implicit
    Agda.Instance {} -> Core.Instance

relevance :: Agda.ArgInfo -> Core.Relevance
relevance info =
  case Agda.getRelevance info of
    Agda.Relevant _ -> Core.Relevant
    _ -> Core.Irrelevant

declarationRole :: Agda.Defn -> Core.DeclarationRole
declarationRole = \case
  Agda.Axiom {} -> Core.AxiomDeclaration
  Agda.Datatype {} -> Core.ComputationalData
  Agda.Record {} -> Core.ComputationalData
  Agda.Constructor {} -> Core.ComputationalWitness
  -- Agda does not separate programs from proofs in Set. A later mapping
  -- registry may promote selected declarations to Lean theorem syntax.
  Agda.Function {} -> Core.ComputationalFunction
  Agda.Primitive {} -> Core.ComputationalFunction
  Agda.PrimitiveSort {} -> Core.ComputationalData
  Agda.AbstractDefn definition -> declarationRole definition
  _ -> Core.Adapter

definitionFeatures :: Agda.Definition -> Set.Set Core.Feature
definitionFeatures definition =
  cubical
    <> recursive
    <> coinductive
    <> termInternalFeatures (Agda.unEl (Agda.defType definition))
    <> definitionKindFeatures (Agda.theDef definition)
  where
    cubical =
      case Agda.defLanguage definition of
        Agda.Cubical _ -> Set.singleton Core.Cubical
        _ -> Set.empty
    recursive =
      case Agda.theDef definition of
        Agda.Function {Agda.funMutual = Just mutual}
          | Agda.defName definition `elem` mutual ->
              Set.singleton Core.StructuralRecursion
        _ -> Set.empty
    coinductive =
      case Agda.theDef definition of
        Agda.Record {Agda.recInduction = Just Agda.CoInductive} ->
          Set.singleton Core.Coinduction
        _ -> Set.empty

definitionKindFeatures :: Agda.Defn -> Set.Set Core.Feature
definitionKindFeatures = \case
  Agda.Function {Agda.funClauses = clauses} -> foldMap clauseFeatures clauses
  Agda.Primitive {Agda.primClauses = clauses} -> foldMap clauseFeatures clauses
  Agda.AbstractDefn inner -> definitionKindFeatures inner
  _ -> Set.empty

clauseFeatures :: Agda.Clause -> Set.Set Core.Feature
clauseFeatures clause =
  foldMap termInternalFeatures (Agda.clauseBody clause)
    <> foldMap
      (termInternalFeatures . Agda.unEl . Agda.unDom)
      (Agda.clauseTel clause)
    <> foldMap
      (termInternalFeatures . Agda.unEl . Agda.unArg)
      (Agda.clauseType clause)

definitionBodyDependencies :: Agda.Definition -> Set.Set Core.CanonicalName
definitionBodyDependencies definition =
  Set.delete
    (canonicalName (Agda.defName definition))
    ( typeGlobalNames (Agda.defType definition)
        <> case Agda.theDef definition of
          Agda.Function {Agda.funClauses = clauses} -> foldMap clauseDependencies clauses
          Agda.Primitive {Agda.primClauses = clauses} -> foldMap clauseDependencies clauses
          Agda.AbstractDefn inner -> definitionKindDependencies inner
          _ -> Set.empty
    )

definitionKindDependencies :: Agda.Defn -> Set.Set Core.CanonicalName
definitionKindDependencies = \case
  Agda.Function {Agda.funClauses = clauses} -> foldMap clauseDependencies clauses
  Agda.Primitive {Agda.primClauses = clauses} -> foldMap clauseDependencies clauses
  Agda.AbstractDefn inner -> definitionKindDependencies inner
  _ -> Set.empty

clauseDependencies :: Agda.Clause -> Set.Set Core.CanonicalName
clauseDependencies clause =
  foldMap termGlobalNames (Agda.clauseBody clause)
    <> foldMap
      (typeGlobalNames . Agda.unDom)
      (Agda.clauseTel clause)
    <> foldMap
      (typeGlobalNames . Agda.unArg)
      (Agda.clauseType clause)

termInternalFeatures :: Agda.Term -> Set.Set Core.Feature
termInternalFeatures = \case
  Agda.Var _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.Lam _ abstraction -> termInternalFeatures (Agda.unAbs abstraction)
  Agda.Lit _ -> Set.empty
  Agda.Def _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.Con _ _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.Pi domain codomain ->
    domainInternalFeatures domain
      <> termInternalFeatures (Agda.unEl (Agda.unAbs codomain))
  Agda.Sort sort' -> sortInternalFeatures sort'
  Agda.Level level -> levelInternalFeatures level
  Agda.MetaV _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.DontCare term -> termInternalFeatures term
  Agda.Dummy kind eliminations ->
    foldMap termInternalFeatures (dummyKindTerms kind)
      <> foldMap eliminationInternalFeatures eliminations

domainInternalFeatures :: Agda.Dom Agda.Type -> Set.Set Core.Feature
domainInternalFeatures domain =
  termInternalFeatures (Agda.unEl (Agda.unDom domain))
    <> foldMap localEquationInternalFeatures (Agda.domEq domain)

localEquationInternalFeatures :: Agda.LocalEquation -> Set.Set Core.Feature
localEquationInternalFeatures equation =
  Set.insert
    Core.RewriteRule
    ( foldMap domainInternalFeatures (Agda.lEqContext equation)
        <> termInternalFeatures (Agda.lEqLHS equation)
        <> termInternalFeatures (Agda.lEqRHS equation)
        <> termInternalFeatures (Agda.unEl (Agda.lEqType equation))
    )

dummyKindTerms :: Agda.DummyTermKind -> [Agda.Term]
dummyKindTerms = \case
  Agda.DummyNamed _ -> []
  Agda.DummyBrave term -> [term]

eliminationInternalFeatures :: Agda.Elim -> Set.Set Core.Feature
eliminationInternalFeatures = \case
  Agda.Apply argument -> termInternalFeatures (Agda.unArg argument)
  Agda.Proj _ _ -> Set.empty
  Agda.IApply left right interval ->
    Set.insert
      Core.Cubical
      ( termInternalFeatures left
          <> termInternalFeatures right
          <> termInternalFeatures interval
      )

sortInternalFeatures :: Agda.Sort -> Set.Set Core.Feature
sortInternalFeatures = \case
  Agda.Type level -> levelInternalFeatures level
  Agda.Prop level -> levelInternalFeatures level
  Agda.SSet level -> levelInternalFeatures level
  Agda.Inf _ _ -> Set.empty
  Agda.SizeUniv -> Set.empty
  Agda.LockUniv -> Set.empty
  Agda.LevelUniv -> Set.empty
  Agda.IntervalUniv -> Set.singleton Core.Cubical
  Agda.PiSort domain sort' abstraction ->
    termInternalFeatures (Agda.unDom domain)
      <> foldMap localEquationInternalFeatures (Agda.domEq domain)
      <> sortInternalFeatures sort'
      <> sortInternalFeatures (Agda.unAbs abstraction)
  Agda.FunSort left right ->
    sortInternalFeatures left <> sortInternalFeatures right
  Agda.UnivSort sort' -> sortInternalFeatures sort'
  Agda.MetaS _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.DefS _ eliminations -> foldMap eliminationInternalFeatures eliminations
  Agda.DummyS _ -> Set.empty

levelInternalFeatures :: Agda.Level -> Set.Set Core.Feature
levelInternalFeatures (Agda.Max _ atoms) =
  foldMap
    (\(Agda.Plus _ atom) -> termInternalFeatures atom)
    atoms

termGlobalNames :: Agda.Term -> Set.Set Core.CanonicalName
termGlobalNames = \case
  Agda.Var _ eliminations -> foldMap eliminationGlobalNames eliminations
  Agda.Lam _ abstraction -> termGlobalNames (Agda.unAbs abstraction)
  Agda.Lit literal ->
    case literal of
      Agda.LitQName name -> Set.singleton (canonicalName name)
      _ -> Set.empty
  Agda.Def name eliminations ->
    Set.insert (canonicalName name) (foldMap eliminationGlobalNames eliminations)
  Agda.Con head' _ eliminations ->
    Set.insert
      (canonicalName (Agda.conName head'))
      (foldMap eliminationGlobalNames eliminations)
  Agda.Pi domain codomain ->
    domainGlobalNames domain
      <> typeGlobalNames (Agda.unAbs codomain)
  Agda.Sort sort' -> sortGlobalNames sort'
  Agda.Level level -> levelGlobalNames level
  Agda.MetaV _ eliminations -> foldMap eliminationGlobalNames eliminations
  Agda.DontCare term -> termGlobalNames term
  Agda.Dummy kind eliminations ->
    foldMap termGlobalNames (dummyKindTerms kind)
      <> foldMap eliminationGlobalNames eliminations

domainGlobalNames :: Agda.Dom Agda.Type -> Set.Set Core.CanonicalName
domainGlobalNames domain =
  typeGlobalNames (Agda.unDom domain)
    <> foldMap localEquationGlobalNames (Agda.domEq domain)

localEquationGlobalNames :: Agda.LocalEquation -> Set.Set Core.CanonicalName
localEquationGlobalNames equation =
  foldMap domainGlobalNames (Agda.lEqContext equation)
    <> termGlobalNames (Agda.lEqLHS equation)
    <> termGlobalNames (Agda.lEqRHS equation)
    <> typeGlobalNames (Agda.lEqType equation)

typeGlobalNames :: Agda.Type -> Set.Set Core.CanonicalName
typeGlobalNames = termGlobalNames . Agda.unEl

eliminationGlobalNames :: Agda.Elim -> Set.Set Core.CanonicalName
eliminationGlobalNames = \case
  Agda.Apply argument -> termGlobalNames (Agda.unArg argument)
  Agda.Proj _ name -> Set.singleton (canonicalName name)
  Agda.IApply left right interval ->
    termGlobalNames left <> termGlobalNames right <> termGlobalNames interval

sortGlobalNames :: Agda.Sort -> Set.Set Core.CanonicalName
sortGlobalNames = \case
  Agda.Type level -> levelGlobalNames level
  Agda.Prop level -> levelGlobalNames level
  Agda.SSet level -> levelGlobalNames level
  Agda.Inf _ _ -> Set.empty
  Agda.SizeUniv -> Set.empty
  Agda.LockUniv -> Set.empty
  Agda.LevelUniv -> Set.empty
  Agda.IntervalUniv -> Set.empty
  Agda.PiSort domain sort' abstraction ->
    termGlobalNames (Agda.unDom domain)
      <> foldMap localEquationGlobalNames (Agda.domEq domain)
      <> sortGlobalNames sort'
      <> sortGlobalNames (Agda.unAbs abstraction)
  Agda.FunSort left right -> sortGlobalNames left <> sortGlobalNames right
  Agda.UnivSort sort' -> sortGlobalNames sort'
  Agda.MetaS _ eliminations -> foldMap eliminationGlobalNames eliminations
  Agda.DefS name eliminations ->
    Set.insert (canonicalName name) (foldMap eliminationGlobalNames eliminations)
  Agda.DummyS _ -> Set.empty

levelGlobalNames :: Agda.Level -> Set.Set Core.CanonicalName
levelGlobalNames (Agda.Max _ atoms) =
  foldMap
    (\(Agda.Plus _ atom) -> termGlobalNames atom)
    atoms

sourceSpan :: Agda.QName -> Core.SourceSpan
sourceSpan name =
  case rangeToIntervalWithFile (getRange name) of
    Nothing -> Core.SourceSpan (Text.pack (prettyShow name)) 1 1
    Just interval ->
      Core.SourceSpan
        { Core.sourceFile =
            case getIntervalFile interval of
              Strict.Nothing -> Text.pack (prettyShow name)
              Strict.Just rangeFile' ->
                Text.pack (filePath (rangeFilePath rangeFile'))
        , Core.sourceStartLine = fromIntegral (posLine (iStart interval))
        , Core.sourceEndLine =
            max
              (fromIntegral (posLine (iStart interval)))
              (fromIntegral (posLine (iEnd interval)))
        }

canonicalName :: Pretty a => a -> Core.CanonicalName
canonicalName = Core.CanonicalName . Text.pack . prettyShow

universeNames :: Snapshot.AgdaTerm -> Set.Set Text.Text
universeNames = \case
  Snapshot.AgdaVar _ eliminations -> foldMap eliminationUniverses eliminations
  Snapshot.AgdaLam binder body ->
    universeNames (Snapshot.agdaBinderType binder) <> universeNames body
  Snapshot.AgdaDef _ eliminations -> foldMap eliminationUniverses eliminations
  Snapshot.AgdaCon _ eliminations -> foldMap eliminationUniverses eliminations
  Snapshot.AgdaPi binder body ->
    universeNames (Snapshot.agdaBinderType binder) <> universeNames body
  Snapshot.AgdaSigma binder body ->
    universeNames (Snapshot.agdaBinderType binder) <> universeNames body
  Snapshot.AgdaSort universe -> universeLevelNames universe
  Snapshot.AgdaLevel level -> levelExpressionNames level
  Snapshot.AgdaEquality type' left right ->
    universeNames type' <> universeNames left <> universeNames right
  Snapshot.AgdaLiteral _ _ -> Set.empty
  Snapshot.AgdaUnsupported _ _ arguments -> foldMap universeNames arguments

levelExpressionNames :: Snapshot.AgdaLevelExpr -> Set.Set Text.Text
levelExpressionNames = \case
  Snapshot.AgdaLevelZero -> Set.empty
  Snapshot.AgdaLevelSuccessor level -> levelExpressionNames level
  Snapshot.AgdaLevelMaximum levels -> foldMap levelExpressionNames levels
  -- The binder is local; declarationUniverses only records free level names.
  Snapshot.AgdaLevelVariable _ -> Set.empty

eliminationUniverses :: Snapshot.AgdaElimination -> Set.Set Text.Text
eliminationUniverses = \case
  Snapshot.AgdaApply _ _ term -> universeNames term
  Snapshot.AgdaProject _ -> Set.empty
  Snapshot.AgdaIntervalApply left right interval ->
    universeNames left <> universeNames right <> universeNames interval

universeLevelNames :: Core.Universe -> Set.Set Text.Text
universeLevelNames = \case
  Core.UZero -> Set.empty
  Core.USuc universe -> universeLevelNames universe
  Core.UMax universes -> foldMap universeLevelNames universes
  Core.ULevel name -> Set.singleton name
  Core.UProp universe -> universeLevelNames universe
  Core.USSet universe -> universeLevelNames universe
