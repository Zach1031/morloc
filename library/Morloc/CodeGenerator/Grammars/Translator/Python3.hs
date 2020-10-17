{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}

{-|
Module      : Morloc.CodeGenerator.Grammars.Translator.Python3
Description : Python3 translator
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.CodeGenerator.Grammars.Translator.Python3
  (
    translate
  , preprocess
  ) where

import Morloc.CodeGenerator.Namespace
import Morloc.CodeGenerator.Grammars.Common
import Morloc.Data.Doc
import Morloc.Quasi
import Morloc.Pretty (prettyType)
import qualified Morloc.Config as MC
import qualified Morloc.Monad as MM
import qualified Morloc.Data.Text as MT
import qualified System.FilePath as SF
import qualified Data.Char as DC

-- tree rewrites
preprocess :: ExprM Many -> MorlocMonad (ExprM Many)
preprocess = invertExprM

translate :: [Source] -> [ExprM One] -> MorlocMonad MDoc
translate srcs es = do
  -- setup library paths
  lib <- fmap pretty $ MM.asks MC.configLibrary

  -- translate sources
  includeDocs <- mapM
    translateSource
    (unique . catMaybes . map srcPath $ srcs)

  -- diagnostics
  liftIO . putDoc $ (vsep $ map prettyExprM es)

  -- translate each manifold tree, rooted on a call from nexus or another pool
  mDocs <- mapM translateManifold es

  -- make code for dispatching to manifolds
  let dispatch = makeDispatch es

  return $ makePool lib includeDocs mDocs dispatch

-- create an internal variable based on a unique id
letNamer :: Int -> MDoc
letNamer i = "a" <> viaShow i

-- create namer for manifold positional arguments
bndNamer :: Int -> MDoc
bndNamer i = "x" <> viaShow i

-- create a name for a manifold based on a unique id
manNamer :: Int -> MDoc
manNamer i = "m" <> viaShow i

-- FIXME: should definitely use namespaces here, not `import *`
translateSource :: Path -> MorlocMonad MDoc
translateSource (Path s) = do
  (Path lib) <- MM.asks configLibrary
  let mod = pretty
          . MT.liftToText (map DC.toLower)
          . MT.replace "/" "."
          . MT.stripPrefixIfPresent "/" -- strip the leading slash (if present)
          . MT.stripPrefixIfPresent "./" -- no path if relative to here
          . MT.stripPrefixIfPresent lib  -- make the path relative to the library
          . MT.liftToText SF.dropExtensions
          $ s
  return $ "from" <+> mod <+> "import *"

-- break a call tree into manifolds
translateManifold :: ExprM One -> MorlocMonad MDoc
translateManifold m@(ManifoldM _ args _) = (vsep . punctuate line . fst) <$> f args m where
  f :: [Argument] -> ExprM One -> MorlocMonad ([MDoc], MDoc)
  f pargs m@(ManifoldM (metaId->i) args e) = do
    (ms', body) <- f args e
    let mname = manNamer i
        head = "def" <+> mname <> tupled (map makeArgument args) <> ":"
        mdoc = nest 4 (vsep [head, body])
    call <- return $ case (splitArgs args pargs, nargsTypeM (typeOfExprM m)) of
      ((rs, []), _) -> mname <> tupled (map makeArgument rs) -- covers #1, #2 and #4
      (([], vs), _) -> mname
      ((rs, vs), _) -> makeLambda vs (mname <> tupled (map makeArgument (rs ++ vs))) -- covers #5
    return (mdoc : ms', call)

  f args (LetM i e1 e2) = do
    (ms1', e1') <- (f args) e1
    (ms2', e2') <- (f args) e2
    return (ms1' ++ ms2', letNamer i <+> "=" <+> e1' <> line <> e2')

  f args (AppM (SrcM _ src) xs) = do
    (mss', xs') <- mapM (f args) xs |>> unzip
    return (concat mss', pretty (srcName src) <> tupled xs')

  f _ (SrcM t src) = return ([], pretty (srcName src))

  f _ (PoolCallM t _ cmds args) = do
    let call = "_morloc_foreign_call(" <> list(map dquotes cmds ++ map makeArgument args) <> ")"
    return ([], call)

  f args (ForeignInterfaceM _ _) = MM.throwError . CallTheMonkeys $
    "Foreign interfaces should have been resolved before passed to the translators"

  f args (LamM lambdaArgs e) = undefined

  f _ (BndVarM _ i) = return ([], bndNamer i)
  f _ (LetVarM _ i) = return ([], letNamer i)
  f args (ListM t es) = do
    (mss', es') <- mapM (f args) es |>> unzip
    return (concat mss', list es')
  f args (TupleM _ es) = do
    (mss', es') <- mapM (f args) es |>> unzip
    return (concat mss', tupled es')
  f args (RecordM c entries) = do
    (mss', es') <- mapM (f args . snd) entries |>> unzip
    let entries' = zipWith (\k v -> pretty k <> "=" <> v) (map fst entries) es'
    return (concat mss', "OrderedDict" <> tupled entries')
  f _ (LogM _ x) = return ([], if x then "True" else "False")
  f _ (NumM _ x) = return ([], viaShow x)
  f _ (StrM _ x) = return ([], dquotes $ pretty x)
  f _ (NullM _) = return ([], "None")
  f args (SerializeM _ e) = do
    (ms, e') <- f args e
    let (Native t) = typeOfExprM e
    return (ms, "mlc_serialize" <> tupled [e', typeSchema t])
  f args (DeserializeM _ e) = do
    (ms, e') <- f args e
    let (Serial t) = typeOfExprM e
    return (ms, "mlc_deserialize" <> tupled [e', typeSchema t])
  f args (ReturnM e) = do
    (ms, e') <- f args e
    return (ms, "return(" <> e' <> ")")


-- divide a list of arguments based on wheither they are in a second list
splitArgs :: [Argument] -> [Argument] -> ([Argument], [Argument])
splitArgs args1 args2 = partitionEithers $ map split args1 where
  split :: Argument -> Either Argument Argument
  split r = if elem r args2
            then Left r
            else Right r


makeLambda :: [Argument] -> MDoc -> MDoc
makeLambda args body = "lambda" <+> hsep (punctuate "," (map makeArgument args)) <> ":" <+> body

makeArgument :: Argument -> MDoc
makeArgument (SerialArgument i c) = bndNamer i
makeArgument (NativeArgument i c) = bndNamer i
makeArgument (PassThroughArgument i) = bndNamer i

makeDispatch :: [ExprM One] -> MDoc
makeDispatch ms = align . vsep $
  [ align . vsep $ ["dispatch = {", indent 4 (vsep $ map entry ms), "}"]
  , "result = dispatch[cmdID](*sys.argv[2:])"
  ]
  where
    entry :: ExprM One -> MDoc
    entry (ManifoldM (metaId->i) _ _)
      = pretty i <> ":" <+> manNamer i <> ","
    entry _ = error "Expected ManifoldM"

typeSchema :: CType -> MDoc
typeSchema c = f (unCType c)
  where
    f (VarT v) = lst [var v, "None"]
    f (ArrT v ps) = lst [var v, lst (map f ps)]
    f (NamT v es) = lst [var v, dict (map entry es)]
    f t = error $ "Cannot serialize this type: " ++ show t

    entry :: (MT.Text, Type) -> MDoc
    entry (v, t) = pretty v <> "=" <> f t

    dict :: [MDoc] -> MDoc
    dict xs = "OrderedDict" <> lst xs

    lst :: [MDoc] -> MDoc
    lst xs = encloseSep "(" ")" "," xs

    var :: TVar -> MDoc
    var (TV _ v) = dquotes (pretty v)

makePool :: MDoc -> [MDoc] -> [MDoc] -> MDoc -> MDoc
makePool lib includeDocs manifolds dispatch = [idoc|#!/usr/bin/env python

import sys
import subprocess
import json
from pymorlocinternals import (mlc_serialize, mlc_deserialize)
from collections import OrderedDict

sys.path = ["#{lib}"] + sys.path

#{vsep includeDocs}

def _morloc_foreign_call(args):
    try:
        sysObj = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            check=True
        )
    except subprocess.CalledProcessError as e:
        sys.exit(str(e))

    return(sysObj.stdout.decode("ascii"))

#{vsep manifolds}

if __name__ == '__main__':
    try:
        cmdID = int(sys.argv[1])
    except IndexError:
        sys.exit("Internal error in {}: no manifold id found".format(sys.argv[0]))
    except ValueError:
        sys.exit("Internal error in {}: expected integer manifold id".format(sys.argv[0]))
    try:
        #{dispatch}
    except KeyError:
        sys.exit("Internal error in {}: no manifold found with id={}".format(sys.argv[0], cmdID))

    print(result)
|]
