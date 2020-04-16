{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}

{-|
Module      : Morloc.CodeGenerator.Grammars.Translator.R
Description : R translator
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.CodeGenerator.Grammars.Translator.R
  ( 
    translate
  ) where

import Morloc.Namespace
import Morloc.CodeGenerator.Grammars.Common
import Morloc.Data.Doc
import Morloc.Quasi
import Morloc.Pretty (prettyType)
import qualified Morloc.Data.Text as MT


translate :: [Source] -> [ExprM] -> MorlocMonad MDoc
translate srcs es = undefined
  -- -- translate sources
  -- includeDocs <- mapM
  --   translateSource
  --   (unique . catMaybes . map srcPath $ srcs)
  --
  -- -- tree rewrites
  -- es' <- mapM (invertExprM namer) es
  --
  -- -- diagnostics
  -- liftIO . putDoc $ (vsep $ map prettyExprM es')
  --
  -- -- translate each manifold tree, rooted on a call from nexus or another pool
  -- mDocs <- mapM translateManifold es'
  --
  -- return $ makePool includeDocs mDocs

varNamer :: Int -> EVar
varNamer i = EVar ("a" <> MT.show' i)

manNamer :: Int -> EVar
manNamer i = EVar ("m" <> MT.show' i)

serialType :: CType
serialType = CType (VarT (TV (Just RLang) "character"))

typeSchema :: CType -> MDoc
typeSchema c = f (unCType c)
  where
    f (VarT v) = dquotes (var v)
    f (ArrT v ps) = lst [var v <> "=" <> lst (map f ps)]
    f (NamT v es) = lst [var v <> "=" <> lst (map entry es)]
    f t = error $ "Cannot serialize this type: " <> show t

    entry :: (MT.Text, Type) -> MDoc
    entry (v, t) = pretty v <> "=" <> f t

    lst :: [MDoc] -> MDoc
    lst xs = "list" <> encloseSep "(" ")" "," xs

    var :: TVar -> MDoc
    var (TV _ v) = pretty v

translateSource :: Path -> MorlocMonad MDoc
translateSource p = return $ "source(" <> dquotes (pretty p) <> ")"

translateManifold :: ExprM -> MorlocMonad MDoc
translateManifold = undefined
-- translateExpr args (LetM v e1 e2) = do
--   e1' <- translateExpr args e1
--   e2' <- translateExpr args e2
--   return $ pretty v <+> "<-" <+> e1' <> line <> e2'
-- translateExpr args (AppM c f es) = do
--   f' <- translateExpr args f
--   es' <- mapM (translateExpr args) es
--   return $ f' <> tupled es' <> " # AppM :: " <> prettyType c
-- translateExpr args (AppM c f@(CisM c' i args') es) = error "FUCK"
-- translateExpr args (LamM c mv e) = do
--   e' <- translateExpr args e
--   let vs = zipWith (\namedVar autoVar -> maybe autoVar (pretty . id) namedVar) mv $
--                    (zipWith (<>) (repeat "p") (map viaShow [1..]))
--   return $ "function" <> tupled vs <> "{" <+> e' <> tupled vs <> "}"
-- translateExpr args (VarM c v) = return (pretty v)
-- translateExpr args (CisM c i args') = return $ "m" <> viaShow i
--   -- return $ case nargs c of
--   --   0 -> "m" <> viaShow i
--   --            <> tupled (map (pretty . argName) args') <+> "# CisM :: " <> prettyType c
--   --   i -> translateExpr args (LamM [
--   -- where
-- translateExpr args (TrsM c i lang) = return "FOREIGN"
-- translateExpr args (ListM _ es) = do
--   es' <- mapM (translateExpr args) es
--   return $ list es'
-- translateExpr args (TupleM _ es) = do
--   es' <- mapM (translateExpr args) es
--   return $ tupled es'
-- translateExpr args (RecordM c entries) = do
--   es' <- mapM (translateExpr args . snd) entries
--   let entries' = zipWith (\k v -> pretty k <> "=" <> v) (map fst entries) es'
--   return $ "dict" <> tupled entries'
-- translateExpr args (LogM c x) = return $ if x then "TRUE" else "FALSE"
-- translateExpr args (NumM c x) = return $ viaShow x
-- translateExpr args (StrM c x) = return . dquotes $ pretty x
-- translateExpr args (NullM c) = return "NULL"
-- translateExpr args (PackM e) = do
--   e' <- translateExpr args e
--   let c = typeOfExprM e
--       schema = typeSchema c
--   return $ "pack" <> tupled [e', schema]
-- translateExpr args (UnpackM e) = do
--   e' <- translateExpr args e
--   let c = typeOfExprM e
--       schema = typeSchema c
--   return $ "unpack" <> tupled [e', schema]
-- translateExpr args (ReturnM e) = do
--   e' <- translateExpr args e
--   return $ "return(" <> e' <> ")"

makeArgument :: Argument -> MDoc
makeArgument (PackedArgument v c) = pretty v
makeArgument (UnpackedArgument v c) = pretty v
makeArgument (PassThroughArgument v) = pretty v

-- returnName :: ReturnValue -> MDoc
-- returnName (PackedReturn v _) = "m" <> pretty v
-- returnName (UnpackedReturn v _) = "m" <> pretty v
-- returnName (PassThroughReturn v) = "m" <> pretty v

makePool :: [MDoc] -> [MDoc] -> MDoc
makePool sources manifolds = [idoc|#!/usr/bin/env Rscript

#{vsep sources}

.morloc_run <- function(f, args){
  fails <- ""
  isOK <- TRUE
  warns <- list()
  notes <- capture.output(
    {
      value <- withCallingHandlers(
        tryCatch(
          do.call(f, args),
          error = function(e) {
            fails <<- e$message;
            isOK <<- FALSE
          }
        ),
        warning = function(w){
          warns <<- append(warns, w$message)
          invokeRestart("muffleWarning")
        }
      )
    },
    type="message"
  )
  list(
    value = value,
    isOK  = isOK,
    fails = fails,
    warns = warns,
    notes = notes
  )
}

# dies on error, ignores warnings and messages
.morloc_try <- function(f, args, .log=stderr(), .pool="_", .name="_"){
  x <- .morloc_run(f=f, args=args)
  location <- sprintf("%s::%s", .pool, .name)
  if(! x$isOK){
    cat("** R errors in ", location, "\n", file=stderr())
    cat(x$fails, "\n", file=stderr())
    stop(1)
  }
  if(! is.null(.log)){
    lines = c()
    if(length(x$warns) > 0){
      cat("** R warnings in ", location, "\n", file=stderr())
      cat(paste(unlist(x$warns), sep="\n"), file=stderr())
    }
    if(length(x$notes) > 0){
      cat("** R messages in ", location, "\n", file=stderr())
      cat(paste(unlist(x$notes), sep="\n"), file=stderr())
    }
  }
  x$value
}

.morloc_unpack <- function(unpacker, x, .pool, .name){
  x <- .morloc_try(f=unpacker, args=list(as.character(x)), .pool=.pool, .name=.name)
  return(x)
}

.morloc_foreign_call <- function(cmd, args, .pool, .name){
  .morloc_try(f=system2, args=list(cmd, args=args, stdout=TRUE), .pool=.pool, .name=.name)
}

#{vsep manifolds}

args <- as.list(commandArgs(trailingOnly=TRUE))
if(length(args) == 0){
  stop("Expected 1 or more arguments")
} else {
  cmdID <- args[[1]]
  f_str <- paste0("m", cmdID)
  if(exists(f_str)){
    f <- eval(parse(text=paste0("m", cmdID)))
    result <- do.call(f, args[-1])
    cat(result, "\n")
  } else {
    cat("Could not find manifold '", cmdID, "'\n", file=stderr())
  }
}
|]
