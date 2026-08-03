{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

module Agda2Lean.Agda.Extract
  ( ExtractionError (..)
  , extractModule
  , renderExtractionError
  ) where

import Agda2Lean.Agda.Snapshot
import Agda2Lean.Classify (classifyModule)
import Agda2Lean.IR
import Control.Monad (foldM)
import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import Data.Word (Word64)

data ExtractionError
  = NegativeDeBruijnIndex CanonicalName Int
  | UnboundDeBruijnIndex CanonicalName Int Int
  | InvalidExtractedModule (Vector.Vector Text)
  deriving stock (Eq, Show)

renderExtractionError :: ExtractionError -> Text
renderExtractionError = \case
  NegativeDeBruijnIndex name index ->
    unCanonicalName name
      <> ": negative de Bruijn index "
      <> Text.pack (show index)
  UnboundDeBruijnIndex name index depth ->
    unCanonicalName name
      <> ": de Bruijn index "
      <> Text.pack (show index)
      <> " exceeds context depth "
      <> Text.pack (show depth)
  InvalidExtractedModule issues ->
    Text.intercalate "\n" (Vector.toList issues)

data ExtractState = ExtractState
  { extractNextTerm :: !Word64
  , extractNextBinder :: !Word64
  , extractTerms :: !(Map TermId CoreTerm)
  , extractInterned :: !(Map CoreTerm TermId)
  , extractBuiltins :: !(Map CanonicalName BuiltinId)
  , extractConstructorBuiltins :: !(Map CanonicalName BuiltinId)
  , extractConstructorIndices :: !(Map CanonicalName Word64)
  , extractProjectionIndices :: !(Map CanonicalName (CanonicalName, Word64))
  }

type ExtractM = StateT ExtractState (Either ExtractionError)

initialState ::
  Map CanonicalName BuiltinId ->
  Map CanonicalName BuiltinId ->
  Map CanonicalName Word64 ->
  Map CanonicalName (CanonicalName, Word64) ->
  ExtractState
initialState builtins constructorBuiltins constructorIndices projectionIndices =
  ExtractState
    { extractNextTerm = 0
    , extractNextBinder = 0
    , extractTerms = Map.empty
    , extractInterned = Map.empty
    , extractBuiltins = builtins
    , extractConstructorBuiltins = constructorBuiltins
    , extractConstructorIndices = constructorIndices
    , extractProjectionIndices = projectionIndices
    }

extractModule :: AgdaModule -> Either ExtractionError ModuleIR
extractModule source = do
  let constructorIndices =
        Map.fromList
          [ (constructor, index)
          | declaration <- Vector.toList (agdaModuleDeclarations source)
          , AgdaDataDefinition schema <- [agdaDeclarationDefinition declaration]
          , (index, constructor) <-
              zip [0 ..] (Vector.toList (agdaDataConstructors schema))
          ]
          <> Map.fromList
            [ (agdaRecordConstructor schema, 0)
            | declaration <- Vector.toList (agdaModuleDeclarations source)
            , AgdaRecordDefinition schema <- [agdaDeclarationDefinition declaration]
            ]
      constructorBuiltins =
        Map.fromList
          [ (constructor, builtin)
          | declaration <- Vector.toList (agdaModuleDeclarations source)
          , Just family <- [agdaDeclarationBuiltin declaration]
          , AgdaDataDefinition schema <- [agdaDeclarationDefinition declaration]
          , (constructor, builtin) <-
              zip
                (Vector.toList (agdaDataConstructors schema))
                (builtinFamilyConstructors family)
          ]
      projectionIndices =
        Map.fromList
          [ (agdaRecordFieldName field, (agdaDeclarationName declaration, index))
          | declaration <- Vector.toList (agdaModuleDeclarations source)
          , AgdaRecordDefinition schema <- [agdaDeclarationDefinition declaration]
          , (index, field) <- zip [0 ..] (Vector.toList (agdaRecordFields schema))
          ]
  (declarations, finalState) <-
    runStateT
      (mapM extractDeclaration (Vector.toList (agdaModuleDeclarations source)))
      ( initialState
          (agdaModuleBuiltins source)
          constructorBuiltins
          constructorIndices
          projectionIndices
      )
  let result =
        ModuleIR
          { moduleSchemaVersion = currentSchemaVersion
          , moduleName = agdaModuleName source
          , moduleImports = agdaModuleImports source
          , moduleTerms = extractTerms finalState
          , moduleDeclarations = Vector.fromList declarations
          }
      classified = classifyModule result
  case validateModule classified of
    Left issues -> Left (InvalidExtractedModule issues)
    Right valid -> Right valid

-- Some Agda 2.9 builtin families bind the datatype semantically without
-- exposing a separate pragma binding for every constructor (notably Nat.zero).
-- Constructor order is part of these builtin datatype schemas, so completing
-- the family here is stable and avoids falling back to textual qualified names.
builtinFamilyConstructors :: BuiltinId -> [BuiltinId]
builtinFamilyConstructors = \case
  BuiltinNat -> [BuiltinNatZero, BuiltinNatSuc]
  BuiltinBool -> [BuiltinBoolFalse, BuiltinBoolTrue]
  BuiltinList -> [BuiltinListNil, BuiltinListCons]
  BuiltinEquality -> [BuiltinRefl]
  _ -> []

extractDeclaration :: AgdaDeclaration -> ExtractM CoreDeclaration
extractDeclaration source = do
  (parameters, _) <-
    foldM
      extractParameter
      ([], [])
      (Vector.toList (agdaDeclarationModuleParameters source))
  typeId <- extractTerm (agdaDeclarationName source) [] (agdaDeclarationType source)
  definition <-
    extractDefinition
      (agdaDeclarationName source)
      (agdaDeclarationDefinition source)
  let roots =
        agdaDeclarationType source
          : definitionTerms (agdaDeclarationDefinition source)
  pure
    CoreDeclaration
      { declarationName = agdaDeclarationName source
      , declarationBuiltin = agdaDeclarationBuiltin source
      , declarationRole = agdaDeclarationRole source
      , declarationUniverses = agdaDeclarationUniverses source
      , declarationModuleParameters = Vector.fromList parameters
      , declarationType = typeId
      , declarationDefinition = definition
      , declarationDependencies =
          Set.delete
            (agdaDeclarationName source)
            ( agdaDeclarationAdditionalDependencies source
                <> foldMap termDependencies roots
                <> definitionPatternDependencies (agdaDeclarationDefinition source)
            )
      , declarationFeatures =
          agdaDeclarationFeatures source <> foldMap termFeatures roots
      , declarationSource = agdaDeclarationSource source
      , declarationMapping = Exact
      }
  where
    extractParameter (parameters, context) binder = do
      typeId <-
        extractTerm
          (agdaDeclarationName source)
          context
          (agdaBinderType binder)
      extracted <- freshBinder binder typeId
      pure (parameters <> [extracted], extracted : context)

extractDefinition ::
  CanonicalName ->
  AgdaDeclarationDefinition ->
  ExtractM DeclarationDefinition
extractDefinition owner = \case
  AgdaTermDefinition body ->
    TermDefinition <$> extractTerm owner [] body
  AgdaClauseDefinition clauses ->
    ClauseDefinition . Vector.fromList
      <$> mapM (extractClause owner) (Vector.toList clauses)
  AgdaDataDefinition schema ->
    pure
      ( DataDefinition
          DataSchema
            { dataParameterCount = agdaDataParameterCount schema
            , dataConstructors = agdaDataConstructors schema
            }
      )
  AgdaRecordDefinition schema ->
    RecordDefinition <$> extractRecordSchema owner schema
  AgdaConstructorDefinition schema ->
    gets (Map.lookup owner . extractConstructorIndices) >>= \case
      Just index ->
        pure
          ( ConstructorDefinition
              ConstructorSchema
                { constructorOwner = agdaConstructorOwner schema
                , constructorIndex = index
                }
          )
      Nothing ->
        pure
          ( BlockedDefinition
              ( UnsupportedDefinitionKind
                  ( unCanonicalName owner
                      <> ": constructor is absent from its owning data schema "
                      <> unCanonicalName (agdaConstructorOwner schema)
                  )
              )
          )
  AgdaProjectionDefinition schema ->
    gets (Map.lookup owner . extractProjectionIndices) >>= \case
      Just (record, index)
        | record == agdaProjectionRecord schema ->
            pure
              ( ProjectionDefinition
                  ProjectionSchema
                    { projectionRecord = record
                    , projectionField = agdaProjectionField schema
                    , projectionIndex = index
                    }
              )
      _ ->
        pure
          ( BlockedDefinition
              ( UnsupportedDefinitionKind
                  ( unCanonicalName owner
                      <> ": projection is absent from record schema "
                      <> unCanonicalName (agdaProjectionRecord schema)
                  )
              )
          )
  AgdaAxiomDefinition -> pure AxiomDefinition
  AgdaBlockedDefinition code detail ->
    pure
      ( BlockedDefinition
          (case code of
             "dependent-pattern" -> UnsupportedDependentPattern detail
             "clause-body" -> UnsupportedClauseBody detail
             _ -> UnsupportedDefinitionKind detail
          )
      )

extractClause :: CanonicalName -> AgdaClause -> ExtractM CoreClause
extractClause owner source = do
  (telescope, context) <-
    foldM
      extractBinder
      ([], [])
      (Vector.toList (agdaClauseTelescope source))
  patterns <-
    mapM
      (extractPattern owner context)
      (Vector.toList (agdaClausePatterns source))
  body <- extractTerm owner context (agdaClauseBody source)
  pure
    CoreClause
      { clauseTelescope = Vector.fromList telescope
      , clausePatterns = Vector.fromList patterns
      , clauseBody = body
      }
  where
    extractBinder (binders, context) binder = do
      typeId <- extractTerm owner context (agdaBinderType binder)
      extracted <- freshBinder binder typeId
      pure (binders <> [extracted], extracted : context)

extractRecordSchema :: CanonicalName -> AgdaRecordSchema -> ExtractM RecordSchema
extractRecordSchema owner source = do
  (parameters, parameterContext) <-
    foldM
      extractBinder
      ([], [])
      (Vector.toList (agdaRecordParameters source))
  (fields, _) <-
    foldM
      extractField
      ([], parameterContext)
      (Vector.toList (agdaRecordFields source))
  pure
    RecordSchema
      { recordConstructor = agdaRecordConstructor source
      , recordParameters = Vector.fromList parameters
      , recordFields = Vector.fromList fields
      }
  where
    extractBinder (binders, context) binder = do
      typeId <- extractTerm owner context (agdaBinderType binder)
      extracted <- freshBinder binder typeId
      pure (binders <> [extracted], extracted : context)

    extractField (fields, context) field = do
      typeId <- extractTerm owner context (agdaRecordFieldType field)
      binder <-
        freshBinder
          AgdaBinder
            { agdaBinderName = canonicalLocalName (agdaRecordFieldName field)
            , agdaBinderType = agdaRecordFieldType field
            , agdaBinderVisibility = Explicit
            , agdaBinderRelevance = Relevant
            }
          typeId
      pure
        ( fields
            <> [ RecordField
                   { recordFieldName = agdaRecordFieldName field
                   , recordFieldBinder = binder
                   }
               ]
        , binder : context
        )

extractPattern :: CanonicalName -> [Binder] -> AgdaPattern -> ExtractM CorePattern
extractPattern owner context = \case
  AgdaPatternVariable index ->
    PatternVariable . binderId <$> lookupBinder owner index context
  AgdaPatternConstructor name patterns -> do
    children <- mapM (extractPattern owner context) (Vector.toList patterns)
    constructorBuiltins <- gets extractConstructorBuiltins
    pure
      ( case Map.lookup name constructorBuiltins of
          Just builtin -> PatternBuiltin builtin (Vector.fromList children)
          Nothing -> PatternConstructor name (Vector.fromList children)
      )
  AgdaPatternBuiltin builtin patterns ->
    PatternBuiltin builtin . Vector.fromList
      <$> mapM (extractPattern owner context) (Vector.toList patterns)
  AgdaPatternLiteral kind value -> pure (PatternLiteral kind value)
  AgdaPatternWildcard -> pure PatternWildcard

extractTerm :: CanonicalName -> [Binder] -> AgdaTerm -> ExtractM TermId
extractTerm owner context = \case
  AgdaVar index eliminations -> do
    binder <- lookupBinder owner index context
    headId <- intern (Var (binderId binder))
    applyEliminations owner context headId eliminations
  AgdaLam sourceBinder body -> do
    typeId <- extractTerm owner context (agdaBinderType sourceBinder)
    binder <- freshBinder sourceBinder typeId
    bodyId <- extractTerm owner (binder : context) body
    intern (Lam binder bodyId)
  AgdaDef name eliminations -> do
    builtins <- gets extractBuiltins
    case Map.lookup name builtins of
      Just BuiltinEquality ->
        case equalityArguments eliminations of
          Just (type', left, right) -> do
            typeId <- extractTerm owner context type'
            leftId <- extractTerm owner context left
            rightId <- extractTerm owner context right
            intern (Equality typeId leftId rightId)
          Nothing -> do
            headId <- intern (Builtin BuiltinEquality)
            applyEliminations owner context headId eliminations
      Just builtin -> do
        headId <- intern (Builtin builtin)
        applyEliminations owner context headId eliminations
      Nothing ->
        case legacyEqualityArguments name eliminations of
          Just (type', left, right) -> do
            typeId <- extractTerm owner context type'
            leftId <- extractTerm owner context left
            rightId <- extractTerm owner context right
            intern (Equality typeId leftId rightId)
          Nothing -> do
            headId <- intern (Axiom name)
            applyEliminations owner context headId eliminations
  AgdaCon name eliminations -> do
    (arguments, residual) <- extractApplyArguments owner context eliminations
    builtins <- gets extractBuiltins
    constructorBuiltins <- gets extractConstructorBuiltins
    case Map.lookup name (Map.union builtins constructorBuiltins) of
      Just builtin -> do
        headId <- intern (Builtin builtin)
        applied <- applyArguments headId arguments
        applyEliminations owner context applied residual
      Nothing -> do
        headId <- intern (Constructor name (Vector.fromList arguments))
        applyEliminations owner context headId residual
  AgdaPi sourceBinder body -> do
    typeId <- extractTerm owner context (agdaBinderType sourceBinder)
    binder <- freshBinder sourceBinder typeId
    bodyId <- extractTerm owner (binder : context) body
    intern (Pi binder bodyId)
  AgdaSigma sourceBinder body -> do
    typeId <- extractTerm owner context (agdaBinderType sourceBinder)
    binder <- freshBinder sourceBinder typeId
    bodyId <- extractTerm owner (binder : context) body
    intern (Sigma binder bodyId)
  AgdaSort universe -> intern (Sort universe)
  AgdaLevel level -> Level <$> extractLevel owner context level >>= intern
  AgdaEquality type' left right -> do
    typeId <- extractTerm owner context type'
    leftId <- extractTerm owner context left
    rightId <- extractTerm owner context right
    intern (Equality typeId leftId rightId)
  AgdaLiteral kind value ->
    intern (Axiom (CanonicalName ("agda2lean.literal." <> kind <> "." <> value)))
  AgdaUnsupported feature label arguments -> do
    argumentIds <- mapM (extractTerm owner context) (Vector.toList arguments)
    intern
      ( Extension
          (case feature of
             Cubical -> CubicalPrimitive label (Vector.fromList argumentIds)
             RewriteRule ->
               RewritePrimitive
                 (CanonicalName ("agda2lean.rewrite." <> safeSegment label))
                 (Vector.fromList argumentIds)
             Coinduction ->
               CoinductivePrimitive label (Vector.fromList argumentIds)
             _ -> UnsafeUniversePrimitive label
          )
      )

extractLevel :: CanonicalName -> [Binder] -> AgdaLevelExpr -> ExtractM LevelExpr
extractLevel owner context = \case
  AgdaLevelZero -> pure LevelZero
  AgdaLevelSuccessor level -> LevelSuccessor <$> extractLevel owner context level
  AgdaLevelMaximum levels ->
    LevelMaximum . Vector.fromList
      <$> mapM (extractLevel owner context) (Vector.toList levels)
  AgdaLevelVariable index ->
    LevelVariable . binderId <$> lookupBinder owner index context

applyArguments :: TermId -> [Argument] -> ExtractM TermId
applyArguments = foldM (\function argument -> intern (App function argument))

extractApplyArguments ::
  CanonicalName ->
  [Binder] ->
  Vector.Vector AgdaElimination ->
  ExtractM ([Argument], Vector.Vector AgdaElimination)
extractApplyArguments owner context eliminations =
  go [] (Vector.toList eliminations)
  where
    go arguments (AgdaApply visibility relevance term : rest) = do
      termId <- extractTerm owner context term
      go (Argument visibility relevance termId : arguments) rest
    go arguments rest = pure (reverse arguments, Vector.fromList rest)

applyEliminations ::
  CanonicalName ->
  [Binder] ->
  TermId ->
  Vector.Vector AgdaElimination ->
  ExtractM TermId
applyEliminations owner context =
  foldM applyOne
  where
    applyOne functionId elimination =
      case elimination of
        AgdaApply visibility relevance term -> do
          argumentId <- extractTerm owner context term
          intern
            (App functionId (Argument visibility relevance argumentId))
        AgdaProject name ->
          intern
            ( Eliminator
                name
                (Vector.singleton (Argument Explicit Relevant functionId))
            )
        AgdaIntervalApply left right interval -> do
          leftId <- extractTerm owner context left
          rightId <- extractTerm owner context right
          intervalId <- extractTerm owner context interval
          intern
            ( Extension
                ( CubicalPrimitive
                    "iapply"
                    (Vector.fromList [functionId, leftId, rightId, intervalId])
                )
            )

lookupBinder :: CanonicalName -> Int -> [Binder] -> ExtractM Binder
lookupBinder owner index context
  | index < 0 = lift (Left (NegativeDeBruijnIndex owner index))
  | otherwise =
      case drop index context of
        binder : _ -> pure binder
        [] -> lift (Left (UnboundDeBruijnIndex owner index (length context)))

freshBinder :: AgdaBinder -> TermId -> ExtractM Binder
freshBinder source typeId = do
  state' <- get
  let identifier = BinderId (extractNextBinder state')
  put state' {extractNextBinder = extractNextBinder state' + 1}
  pure
    Binder
      { binderId = identifier
      , binderName = agdaBinderName source
      , binderType = typeId
      , binderVisibility = agdaBinderVisibility source
      , binderRelevance = agdaBinderRelevance source
      }

intern :: CoreTerm -> ExtractM TermId
intern term = do
  state' <- get
  case Map.lookup term (extractInterned state') of
    Just identifier -> pure identifier
    Nothing -> do
      let identifier = TermId (extractNextTerm state')
      put
        state'
          { extractNextTerm = extractNextTerm state' + 1
          , extractTerms = Map.insert identifier term (extractTerms state')
          , extractInterned = Map.insert term identifier (extractInterned state')
          }
      pure identifier

definitionTerms :: AgdaDeclarationDefinition -> [AgdaTerm]
definitionTerms = \case
  AgdaTermDefinition body -> [body]
  AgdaClauseDefinition clauses ->
    concatMap clauseTerms (Vector.toList clauses)
  AgdaRecordDefinition schema ->
    map agdaBinderType (Vector.toList (agdaRecordParameters schema))
      <> map agdaRecordFieldType (Vector.toList (agdaRecordFields schema))
  AgdaDataDefinition _ -> []
  AgdaConstructorDefinition _ -> []
  AgdaProjectionDefinition _ -> []
  AgdaAxiomDefinition -> []
  AgdaBlockedDefinition _ _ -> []
  where
    clauseTerms clause =
      agdaClauseBody clause
        : map agdaBinderType (Vector.toList (agdaClauseTelescope clause))

definitionPatternDependencies :: AgdaDeclarationDefinition -> Set CanonicalName
definitionPatternDependencies = \case
  AgdaClauseDefinition clauses ->
    foldMap
      (foldMap patternDependencies . agdaClausePatterns)
      clauses
  _ -> Set.empty

patternDependencies :: AgdaPattern -> Set CanonicalName
patternDependencies = \case
  AgdaPatternVariable _ -> Set.empty
  AgdaPatternConstructor name patterns ->
    Set.insert name (foldMap patternDependencies patterns)
  AgdaPatternBuiltin _ patterns -> foldMap patternDependencies patterns
  AgdaPatternLiteral _ _ -> Set.empty
  AgdaPatternWildcard -> Set.empty

termDependencies :: AgdaTerm -> Set CanonicalName
termDependencies = \case
  AgdaVar _ eliminations -> foldMap eliminationDependencies eliminations
  AgdaLam binder body -> termDependencies (agdaBinderType binder) <> termDependencies body
  AgdaDef name eliminations -> Set.insert name (foldMap eliminationDependencies eliminations)
  AgdaCon name eliminations -> Set.insert name (foldMap eliminationDependencies eliminations)
  AgdaPi binder body -> termDependencies (agdaBinderType binder) <> termDependencies body
  AgdaSigma binder body -> termDependencies (agdaBinderType binder) <> termDependencies body
  AgdaSort _ -> Set.empty
  AgdaLevel _ -> Set.empty
  AgdaEquality type' left right ->
    termDependencies type' <> termDependencies left <> termDependencies right
  AgdaLiteral _ _ -> Set.empty
  AgdaUnsupported _ _ arguments -> foldMap termDependencies arguments

eliminationDependencies :: AgdaElimination -> Set CanonicalName
eliminationDependencies = \case
  AgdaApply _ _ term -> termDependencies term
  AgdaProject name -> Set.singleton name
  AgdaIntervalApply left right interval ->
    termDependencies left <> termDependencies right <> termDependencies interval

termFeatures :: AgdaTerm -> Set Feature
termFeatures = \case
  AgdaVar _ eliminations -> foldMap eliminationFeatures eliminations
  AgdaLam binder body -> termFeatures (agdaBinderType binder) <> termFeatures body
  AgdaDef _ eliminations -> foldMap eliminationFeatures eliminations
  AgdaCon _ eliminations -> foldMap eliminationFeatures eliminations
  AgdaPi binder body -> termFeatures (agdaBinderType binder) <> termFeatures body
  AgdaSigma binder body -> termFeatures (agdaBinderType binder) <> termFeatures body
  AgdaSort _ -> Set.empty
  AgdaLevel _ -> Set.empty
  AgdaEquality type' left right ->
    Set.insert OrdinaryEquality
      (termFeatures type' <> termFeatures left <> termFeatures right)
  AgdaLiteral _ _ -> Set.empty
  AgdaUnsupported feature _ arguments ->
    Set.insert feature (foldMap termFeatures arguments)

eliminationFeatures :: AgdaElimination -> Set Feature
eliminationFeatures = \case
  AgdaApply _ _ term -> termFeatures term
  AgdaProject _ -> Set.empty
  AgdaIntervalApply left right interval ->
    Set.insert Cubical
      (termFeatures left <> termFeatures right <> termFeatures interval)

safeSegment :: Text -> Text
safeSegment value =
  let result = Text.map (\character -> if character == '.' then '_' else character) value
   in if Text.null result then "unnamed" else result

canonicalLocalName :: CanonicalName -> Text
canonicalLocalName name =
  case reverse (Text.splitOn "." (unCanonicalName name)) of
    local : _ | not (Text.null local) -> local
    _ -> "field"

equalityArguments ::
  Vector.Vector AgdaElimination ->
  Maybe (AgdaTerm, AgdaTerm, AgdaTerm)
equalityArguments eliminations =
  case reverse
      [ term
      | AgdaApply _ _ term <- Vector.toList eliminations
      ] of
    right : left : type' : _ -> Just (type', left, right)
    _ -> Nothing

legacyEqualityArguments ::
  CanonicalName ->
  Vector.Vector AgdaElimination ->
  Maybe (AgdaTerm, AgdaTerm, AgdaTerm)
legacyEqualityArguments name eliminations
  | unCanonicalName name == "Agda.Builtin.Equality._≡_" =
      equalityArguments eliminations
  | otherwise = Nothing
