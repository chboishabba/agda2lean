{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Registry.File
  ( loadRegistryLayer
  , parseRegistryLayer
  , renderRegistryLayer
  ) where

import Agda2Lean.Platform
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text

loadRegistryLayer :: RegistryScope -> FilePath -> IO RegistryLayer
loadRegistryLayer expectedScope path = do
  contents <- Text.readFile path
  layer <- either (ioError . userError . Text.unpack) pure (parseRegistryLayer contents)
  if registryLayerScope layer == expectedScope
    then pure layer
    else
      ioError
        ( userError
            ( "registry scope mismatch for "
                <> path
                <> ": expected "
                <> show expectedScope
                <> ", found "
                <> show (registryLayerScope layer)
            )
        )

parseRegistryLayer :: Text -> Either Text RegistryLayer
parseRegistryLayer contents = do
  name <- requiredHeader "registry-name"
  version <- requiredHeader "registry-version"
  scopeText <- requiredHeader "registry-scope"
  scope <- parseShown "registry scope" scopeText
  mappings <- traverse (parseMapping scope) dataLines
  pure
    RegistryLayer
      { registryLayerName = name
      , registryLayerVersion = version
      , registryLayerScope = scope
      , registryLayerMappings = mappings
      }
  where
    rawLines = filter (not . Text.null) (map Text.strip (Text.lines contents))
    headers =
      [ (key, Text.drop 1 value)
      | line <- rawLines
      , Just body <- [Text.stripPrefix "# " line]
      , let (key, value) = Text.breakOn "\t" body
      , not (Text.null value)
      ]
    dataLines =
      [ line
      | line <- rawLines
      , not ("#" `Text.isPrefixOf` line)
      , not ("builtin-id\t" `Text.isPrefixOf` line)
      ]
    requiredHeader key =
      maybe
        (Left ("missing registry header: " <> key))
        Right
        (lookup key headers)

parseMapping :: RegistryScope -> Text -> Either Text PlatformMapping
parseMapping scope line =
  case Text.splitOn "\t" line of
    [builtinText, auditName, target, rule, computationText, axiomEffectText, axiomDeltaText, kindText] -> do
      builtin <- parseShown "BuiltinId" builtinText
      computation <- parseShown "computation treatment" computationText
      axiomEffect <- parseShown "axiom effect" axiomEffectText
      entityKind <- parseShown "builtin entity kind" kindText
      pure
        PlatformMapping
          { platformBuiltin = builtin
          , platformAuditName = auditName
          , platformTarget = target
          , platformMode = rule
          , platformComputation = computation
          , platformAxiomEffect = axiomEffect
          , platformAxiomDelta = parseAxiomDelta axiomDeltaText
          , platformEntityKind = entityKind
          , platformScope = scope
          }
    columns ->
      Left
        ( "registry row must contain 8 tab-separated columns, found "
            <> Text.pack (show (length columns))
            <> ": "
            <> line
        )

renderRegistryLayer :: RegistryLayer -> Text
renderRegistryLayer layer =
  Text.unlines
    ( [ "# registry-name\t" <> registryLayerName layer
      , "# registry-version\t" <> registryLayerVersion layer
      , "# registry-scope\t" <> Text.pack (show (registryLayerScope layer))
      , "builtin-id\tagda-binding\tlean-target\trule\tcomputation\taxiom-effect\taxiom-delta\tentity-kind"
      ]
        <> map renderMapping (registryLayerMappings layer)
    )
  where
    renderMapping mapping =
      Text.intercalate
        "\t"
        [ Text.pack (show (platformBuiltin mapping))
        , platformAuditName mapping
        , platformTarget mapping
        , platformMode mapping
        , Text.pack (show (platformComputation mapping))
        , Text.pack (show (platformAxiomEffect mapping))
        , if null (platformAxiomDelta mapping) then "-" else Text.intercalate "," (platformAxiomDelta mapping)
        , Text.pack (show (platformEntityKind mapping))
        ]

parseAxiomDelta :: Text -> [Text]
parseAxiomDelta value
  | value == "-" || Text.null value = []
  | otherwise = filter (not . Text.null) (map Text.strip (Text.splitOn "," value))

parseShown :: (Bounded a, Enum a, Show a) => Text -> Text -> Either Text a
parseShown label value =
  maybe
    (Left ("unknown " <> label <> ": " <> value))
    Right
    (find ((== value) . Text.pack . show) [minBound .. maxBound])
