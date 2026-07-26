{-# LANGUAGE OverloadedStrings #-}

module Agda2Lean.Render
  ( renderCatalogIssues
  , renderCatalogStats
  , renderModule
  , renderModuleSummaries
  ) where

import Agda2Lean.Catalog
import Agda2Lean.Hash (renderObjectHash)
import Agda2Lean.IR
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Vector as Vector

renderModuleSummaries :: [ModuleSummary] -> Text
renderModuleSummaries summaries =
  renderRows
    ["MODULE", "DECLS", "TERMS", "BYTES", "OBJECT"]
    [ [ summaryModuleName summary
      , showText (summaryDeclarationCount summary)
      , showText (summaryTermCount summary)
      , showText (summaryObjectBytes summary)
      , Text.take 16 (renderObjectHash (summaryObjectHash summary))
      ]
    | summary <- summaries
    ]

renderCatalogStats :: CatalogStats -> Text
renderCatalogStats stats =
  renderRows
    ["METRIC", "VALUE"]
    [ ["modules", showText (statsModules stats)]
    , ["declarations", showText (statsDeclarations stats)]
    , ["immutable objects", showText (statsObjects stats)]
    , ["object bytes", showText (statsObjectBytes stats)]
    , ["direct dependencies", showText (statsDirectDependencies stats)]
    ]

renderModule :: ModuleIR -> Text
renderModule moduleIR =
  Text.unlines
    [ "Module: " <> unCanonicalName (moduleName moduleIR)
    , "Schema: " <> showText (unSchemaVersion (moduleSchemaVersion moduleIR))
    , "Imports: " <> showText (Set.size (moduleImports moduleIR))
    , "Terms: " <> showText (Map.size (moduleTerms moduleIR))
    , "Declarations: " <> showText (Vector.length declarations)
    , ""
    , renderRows
        ["DECLARATION", "ROLE", "MAPPING", "DEPENDENCIES"]
        [ [ unCanonicalName (declarationName declaration)
          , showText (declarationRole declaration)
          , showText (declarationMapping declaration)
          , showText (Set.size (declarationDependencies declaration))
          ]
        | declaration <- Vector.toList declarations
        ]
    ]
  where
    declarations = moduleDeclarations moduleIR

renderCatalogIssues :: [CatalogIssue] -> Text
renderCatalogIssues [] = "catalog verified: all objects are canonical and intact\n"
renderCatalogIssues issues =
  renderRows
    ["OBJECT", "ISSUE"]
    [ [ Text.take 16 (renderObjectHash (issueObjectHash issue))
      , issueDescription issue
      ]
    | issue <- issues
    ]

renderRows :: [Text] -> [[Text]] -> Text
renderRows headers rows =
  Text.unlines
    ( renderRow widths headers
        : renderRow widths (map (\width -> Text.replicate width "-") widths)
        : map (renderRow widths) rows
    )
  where
    columnCount = length headers
    normalizedRows = map (take columnCount . (<> repeat "")) rows
    widths =
      foldl
        (zipWith max)
        (map Text.length headers)
        (map (map Text.length) normalizedRows)

renderRow :: [Int] -> [Text] -> Text
renderRow widths values =
  Text.intercalate "  " (zipWith Text.justifyLeft widths ' ' values)

showText :: Show a => a -> Text
showText = Text.pack . show
