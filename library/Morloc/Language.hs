{-# LANGUAGE OverloadedStrings #-}

module Morloc.Language (
    CodeGenerator(..)
  , rCodeGenerator
) where

import qualified Data.Text as DT

import Morloc.Operators
import qualified Morloc.Util as MU

data CodeGenerator = CodeGenerator {
      makePool
        :: [DT.Text] -- any required global declarations
        -> [DT.Text] -- any input source code
        -> [DT.Text] -- the node function declarations
        -> DT.Text   -- entire pool script

    , makeSource
        :: DT.Text -- path
        -> DT.Text

    , makeCall
        :: DT.Text   -- function name
        -> [DT.Text] -- arguments
        -> DT.Text

    , makeFunction
        :: DT.Text   -- function name
        -> [DT.Text] -- function arguments
        -> DT.Text   -- function body
        -> DT.Text

    , makeManifoldName
        :: DT.Text -- RDF unique ID (e.g. "mid:42")
        -> DT.Text
  }

rCodeGenerator :: CodeGenerator
rCodeGenerator = CodeGenerator {
      makePool     = makePool'
    , makeSource   = makeSource'
    , makeCall     = makeCall'
    , makeFunction = makeFunction'
    , makeManifoldName = makeManifoldName'
  }
  where

    makePool' :: [DT.Text] -> [DT.Text] -> [DT.Text] -> DT.Text
    makePool' gs is fs = DT.unlines . concat $ [begin', gs, is, fs, end']

    makeSource' :: DT.Text -> DT.Text 
    makeSource' path = "source(" <> path <> ")"

    makeCall' :: DT.Text -> [DT.Text] -> DT.Text
    makeCall' fname args = fname <> "(" <> DT.intercalate ", " args <> ")" 

    makeFunction' :: DT.Text -> [DT.Text] -> DT.Text -> DT.Text
    makeFunction' name args body
      =  name <> " <- function (" <> DT.intercalate ", " args <> ")"
      <> "{\n" <> MU.indent 2 body <> "}\n"

    makeManifoldName' :: DT.Text -> DT.Text
    makeManifoldName' t = case DT.splitOn ":" t of
      [_, i] -> "m" <> i
      _ -> "XXX"

    begin' = ["#!/usr/bin/env Rscript"]

    end'   =
      [ "args <- commandArgs(trailingOnly=TRUE)"
      , "if(length(args) == 0){"
      , "  stop(\"Expected 1 or more arguments\")"
      , "} else if(exists(args[[1]])){"
      , "  x <- get(args[[1]])"
      , "  result <- if(class(x) == \"function\"){"
      , "    par <- lapply(args[-1], function(s) eval(parse(text=s)))"
      , "    do.call(get(args[[1]]), par)"
      , "  } else {"
      , "    x"
      , "  }"
      , "  cat(result, \"\\n\")"
      , "} else {"
      , "  stop(\"Could not find function '\", f, \"'\")"
      , "}"
      ]
