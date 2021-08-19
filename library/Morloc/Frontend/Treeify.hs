{-|
Module      : Morloc.Frontend.Treeify
Description : Translate from the frontend DAG to the backend SAnno AST forest
Copyright   : (c) Zebulun Arendsee, 2021
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Frontend.Treeify (treeify) where

import Morloc.Frontend.Namespace
import Morloc.Data.Doc
import Morloc.Frontend.PartialOrder ()
import qualified Control.Monad.State as CMS
import qualified Morloc.Frontend.AST as AST
import qualified Morloc.Data.Text as MT
import qualified Morloc.Monad as MM
import qualified Morloc.Data.DAG as DAG
import qualified Morloc.Data.Map as Map
import qualified Data.Set as Set
import qualified Morloc.Data.GMap as GMap

-- | Every term must either be sourced or declared.
data TermOrigin = Declared ExprI | Sourced Source
  deriving(Show, Ord, Eq)

-- When I see a term, I need to look it up. To do so, I need to walk up through
-- scope until I find a source/declaration and all type annotations. This involves
-- walking up through where statements (shadowing is possible), up through lambdas
-- (where again shadowing is possible), to the module scope, and to the imported
-- scope (where shadowing is not allowed).
--
-- Generate integers for all positions in the tree, use these to map into a table that includes:
--  * manual type annotations or signatures
--  * inferred type annotations

-- all expressions are mapped to integers that serve as indices linking
-- expressions to their ultimate type annotations. The indices also match terms
-- to their signatures or (eventually) to locations in source code.
treeify
  :: DAG MVar [(EVar, EVar)] ExprI
  -> MorlocMonad [SAnno Int Many [EType]]
treeify d
 | Map.size d == 0 = return []
 | otherwise = case DAG.roots d of
   -- if no parentless element exists, then the graph must be empty or cyclic
   [] -> MM.throwError CyclicDependency
   -- else if exactly one module name key (k) is found
   [k] -> case DAG.lookupNode k d of
     -- if the key is not in the DAG, then something is dreadfully wrong codewise
     Nothing -> MM.throwError . DagMissingKey . render $ pretty k
     (Just e) -> do
       -- start counter for type keys
       MM.startCounter

       -- build a map
       -- - fill stateSignatures map in the MorlocState reader monad
       --       stateSignatures :: GMap Int Int [EType]
       -- - this is a map from term (VarE) indices to signature sets
       -- - after this step, all signatures and type annotation expressions are redundant
       -- - the map won't be used until the type inference step in Infer.hs
       _ <- DAG.synthesizeDAG linkSignaturesModule d

       -- set counter for reindexing expressions in collect
       MM.setCounter $ maximum (map AST.maxIndex (DAG.nodes d)) + 1

       -- dissolve modules, imports, and sources, leaving behind only a tree for each term exported from main
       mapM (collect e) (AST.findExports e)

   -- There is no currently supported use case that exposes multiple roots in
   -- one compilation process. The compiler executable takes a single morloc
   -- file as input, therefore this MUST be the root. In the future compiling
   -- multiple projects in parallel with potentially shared information and
   -- constraints could be valuable.
   _ -> MM.throwError . CallTheMonkeys $ "How did you end up with so many roots?"


{-
                ,--n-> Source <-m--n-> Concrete Signature
term --<i>--.--<
             \  `--m-> Declaration
              `------------------------n--> General Signature
-}


-- in each scope (top of a module or after descending into a where statement) 
--  1 collect all type signatures (Map EVar [EType])
--  2 find all equivalent appearences of a given term across modules (including across aliases)
linkSignaturesModule
  :: MVar
  -> ExprI
  -> [(MVar, [(EVar, EVar)], Map.Map EVar TermTypes)]
  -- ^ This is a list of 
  -> MorlocMonad (Map.Map EVar TermTypes)
linkSignaturesModule _ (ExprI _ (ModE v es)) edges
  -- a map from alias to all signatures associated with the alias
  = Map.mapM (foldlM combineTermTypes (TermTypes Nothing [] []))
              (Map.unionsWith (<>) [unalias es' m' | (_, es', m') <- edges]) >>=
    linkSignatures v es
  where
  -- map from a srcname linking to an alias linking
  -- NOTE: This is NOT a one to one mapping. Many sources may map to one alias.
  --   import A (foo as f, bar as f, baz as g)
  --   [("f", [x, y]), ("g", [z])] -- where x,y, and z values of type `a`
  unalias :: [(EVar, EVar)] -> Map.Map EVar a -> Map.Map EVar [a]
  unalias es0 m =
    let aliases = Map.fromList . groupSort $ [(alias, srcname) | (srcname, alias) <- es0]
    in Map.map (mapMaybe (flip Map.lookup $ m)) aliases
linkSignaturesModule _ _ _ = MM.throwError . CallTheMonkeys $ "Expected a module at the top level" 

linkSignatures :: MVar -> [ExprI] -> Map.Map EVar TermTypes -> MorlocMonad (Map.Map EVar TermTypes)
linkSignatures v es m = do
  -- find all top-level terms in this module
  --   terms :: Map.Map EVar TermTypes
  -- there is a lot of checking happening here, we ensure that
  --   - concrete type signatures appear only where there is a source statement
  --   - there can be only one general type in a given scope for a given term
  terms <- unifyTermTypes v es m

  -- Map EVar (Int, TermTypes)
  iterms <- Map.mapM indexTerm terms

  -- link terms to types
  _ <- linkVariablesToTermTypes v iterms es

  return terms

indexTerm :: a -> MorlocMonad (Int, a)
indexTerm x = do
  s <- CMS.get
  let i = stateCounter s
  CMS.put (s { stateCounter = i + 1 })
  return (i, x)

linkVariablesToTermTypes :: MVar -> Map.Map EVar (Int, TermTypes) -> [ExprI] -> MorlocMonad ()
linkVariablesToTermTypes mod m0 = mapM_ (link m0) where 
  link :: Map.Map EVar (Int, TermTypes) -> ExprI -> MorlocMonad ()
  link m (ExprI _ (ModE v es)) = undefined -- TODO: how should nested modules behave?
  link m (ExprI i (ExpE v)) = setType m i v
  link m (ExprI i (Declaration v (ExprI _ (LamE ks e)) es)) = do
    -- shadow all bound terms
    let m' = foldr Map.delete m ks
    setType m' i v
    linkSignatures mod (e:es) (Map.map snd m')
    return ()
  link m (ExprI i (VarE v)) = setType m i v
  link m (ExprI _ (AccE e _)) = link m e
  link m (ExprI _ (ListE xs)) = mapM_ (link m) xs
  link m (ExprI _ (TupleE xs)) = mapM_ (link m) xs
  link m (ExprI _ (LamE vs e)) = link (foldr Map.delete m vs) e
  link m (ExprI _ (AppE f es)) = link m f >> mapM_ (link m) es
  link m (ExprI _ (AnnE e _)) = link m e
  link m (ExprI _ (RecE rs)) = mapM_ (link m) (map snd rs)
  link _ _ = return ()

  setType :: Map.Map EVar (Int, TermTypes) -> Int -> EVar -> MorlocMonad ()
  setType m i v = case Map.lookup v m of 
    (Just (j, t)) -> do
      s <- CMS.get
      CMS.put (s {stateSignatures = GMap.insert i j t (stateSignatures s)})
      return ()
    Nothing -> return ()

unifyTermTypes :: MVar -> [ExprI] -> Map.Map EVar TermTypes -> MorlocMonad (Map.Map EVar TermTypes)
unifyTermTypes mod xs m0
  = Map.mergeMapsM fb fc fbc sigs srcs
  >>= Map.mapKeysWithM combineTermTypes (\(v,_,_) -> v)
  >>= Map.unionWithM combineTermTypes m0
  >>= Map.unionWithM combineTermTypes decs
  where
  sigs = Map.fromListWith (<>) [((v, l, langOf t), [t]) | (ExprI _ (Signature v l t)) <- xs]
  srcs = Map.fromListWith (<>) [((srcAlias s, srcLabel s, langOf s), [s]) | (ExprI _ (SrcE s)) <- xs]
  decs = Map.map (TermTypes Nothing []) $ Map.fromListWith (<>) [(v, [e]) | (ExprI _ (Declaration v e _)) <- xs]

  fb :: [EType] -> MorlocMonad TermTypes
  fb [] = MM.throwError . CallTheMonkeys $ "This case should not appear given the construction of the map"
  fb [e] = return $ TermTypes (Just e) [] []
  -- TODO: clean up the error messages to say exactly what went wrong (and
  -- don't call the monkeys, this is not an internal error).
  fb es = MM.throwError . CallTheMonkeys $ "Either you wrote a concrete type signature with no associated source function or you wrote multiple general type signatures for a single term in a single scope - either way, you can't do that."

  -- Should we even allow concrete terms with no type signatures?
  fc :: [Source] -> MorlocMonad TermTypes
  fc srcs = return $ TermTypes Nothing [(mod, src, []) | src <- srcs] []

  fbc :: [EType] -> [Source] -> MorlocMonad TermTypes
  fbc sigs srcs = do
    let gsigs = [t | t <- sigs, isJust (langOf t)]
    let csigs = [t | t <- sigs, isNothing (langOf t)]
    gtype <- case gsigs of
      [e] -> return (Just e)
      [] -> return Nothing
      -- TODO: don't call the monkeys
      _ -> MM.throwError . CallTheMonkeys $ "Expected a single general type"
    return $ TermTypes gtype [(mod, src, csigs) | src <- srcs] []


combineTermTypes :: TermTypes -> TermTypes -> MorlocMonad TermTypes
combineTermTypes (TermTypes g1 cs1 es1) (TermTypes g2 cs2 es2)
  = TermTypes
  <$> (sequence $ mergeEType <$> g1 <*> g2)
  <*> pure (unique (cs1 <> cs2))
  <*> pure (unique (es1 <> es2))


-- | This function defines who general types are merged. There are decisions
-- encoded in this function that should be vary carefully considered.
--  * Can properties simply be concatenated?
--  * What if constraints are contradictory?
mergeEType :: EType -> EType -> MorlocMonad EType
mergeEType (EType t1 ps1 cs1) (EType t2 ps2 cs2)
  = EType <$> mergeUnresolvedTypes t1 t2 <*> pure (ps1 <> ps2) <*> pure (cs1 <> cs2)


mergeUnresolvedTypes :: UnresolvedType -> UnresolvedType -> MorlocMonad UnresolvedType
mergeUnresolvedTypes t1@(VarU v1) t2@(VarU v2)
  | v1 == v2 = return (VarU v1)
  | otherwise = MM.throwError $ IncompatibleGeneralType t1 t2 
mergeUnresolvedTypes t@(ExistU _ _ _) (ExistU _ _ _) = return t
mergeUnresolvedTypes (ExistU _ _ _) t = return t
mergeUnresolvedTypes t (ExistU _ _ _) = return t
mergeUnresolvedTypes (ForallU v1 t1) (ForallU v2 t2) = undefined
mergeUnresolvedTypes (FunU f1 x1) (FunU f2 x2) = undefined
mergeUnresolvedTypes (ArrU v1 ps1) (ArrU v2 ps2) = undefined
mergeUnresolvedTypes (NamU t1 v1 ps1 ks1) (NamU t2 v2 ps2 ks2) = undefined
mergeUnresolvedTypes t1 t2 = MM.throwError $ IncompatibleGeneralType t1 t2

-- | Build the call tree for a single nexus command. The result is ambiguous,
-- with 1 or more possible tree topologies, each with one or more possible for
-- each function.
--
-- Recursion
--   [ ] handle recursion and mutual recursion
--       - to detect recursion, I need to remember every term that has been expanded, 
-- collect v declarations or sources
collect
  :: ExprI
  -> (Int, EVar) -- The Int is the index for the export term
  -> MorlocMonad (SAnno Int Many [EType])
collect (ExprI _ (ModE _ _)) (i, v) = do
  t <- lookupSig i
  case t of
    -- if Nothing, then the term is a bound variable
    Nothing -> MM.throwError . CallTheMonkeys $ "Exported terms should map to signatures"
    -- otherwise is an alias that should be replaced with its value(s)
    (Just t) -> do
      let calls = [(CallS src, ts) | (_, src, ts) <- termConcrete t]
      declarations <- mapM collectSExpr (termDecl t)
      return $ SAnno (Many (calls <> declarations)) i
collect (ExprI _ _) _ = MM.throwError . CallTheMonkeys $ "The top should be a module"

-- | Find the user provided, or module imported, general type annotations and
-- collect info needed for the GMeta object
collectSAnno :: ExprI -> MorlocMonad (SAnno Int Many [EType])
collectSAnno e@(ExprI i (VarE v)) = do
  t <- lookupSig i
  es <- case t of
    -- if Nothing, then the term is a bound variable
    Nothing -> collectSExpr e |>> return
    -- otherwise is an alias that should be replaced with its value(s)
    (Just t) -> do
      let calls = [(CallS src, ts) | (_, src, ts) <- termConcrete t]
      declarations <- mapM reindexExprI (termDecl t) >>= mapM collectSExpr
      return $ (calls <> declarations)
  return $ SAnno (Many es) i

-- expression type annotations should have already been accounted for, so ignore
collectSAnno (ExprI _ (AnnE e _)) = collectSAnno e
collectSAnno e@(ExprI i _) = do
  e' <- collectSExpr e 
  return $ SAnno (Many [e']) i

-- | Find all definitions of a term and collect their type annotations, if available
collectSExpr :: ExprI -> MorlocMonad (SExpr Int Many [EType], [EType])
collectSExpr (ExprI i e0) = f e0 where
  f (VarE v) = noTypes (VarS v) -- this must be a bound variable
  f (AccE e x) = (AccS <$> collectSAnno e <*> pure x) >>= noTypes
  f (ListE es) = (ListS <$> mapM collectSAnno es) >>= noTypes
  f (TupleE es) = (TupleS <$> mapM collectSAnno es) >>= noTypes
  f (RecE rs) = do
    xs <- mapM collectSAnno (map snd rs)
    noTypes $ RecS (zip (map fst rs) xs)
  f (LamE v e) = LamS v <$> collectSAnno e >>= noTypes
  f (AppE e es) = (AppS <$> collectSAnno e <*> mapM collectSAnno es) >>= noTypes
  f UniE = noTypes UniS
  f (NumE x) = noTypes (NumS x)
  f (LogE x) = noTypes (LogS x)
  f (StrE x) = noTypes (StrS x)

  -- none of the following cases should every occur
  f (AnnE _ _) = undefined
  f (TypE _ _ _) = undefined
  f (ImpE _) = undefined
  f (ExpE _) = undefined
  f (SrcE _) = undefined
  f (Signature _ _ _) = undefined
  f (Declaration _ _ _) = undefined

  noTypes x = return (x, [])

reindexExprI :: ExprI -> MorlocMonad ExprI
reindexExprI (ExprI i e) = ExprI <$> newIndex i <*> reindexExpr e

reindexExpr :: Expr -> MorlocMonad Expr
reindexExpr (ModE m es) = ModE m <$> mapM reindexExprI es
reindexExpr (AccE e x) = AccE <$> reindexExprI e <*> pure x
reindexExpr (AnnE e ts) = AnnE <$> reindexExprI e <*> pure ts
reindexExpr (AppE e es) = AppE <$> reindexExprI e <*> mapM reindexExprI es
reindexExpr (Declaration v e es) = Declaration v <$> reindexExprI e <*> mapM reindexExprI es
reindexExpr (LamE vs e) = LamE vs <$> reindexExprI e
reindexExpr (ListE es) = ListE <$> mapM reindexExprI es
reindexExpr (RecE rs) = RecE <$> mapM (\(k, e) -> (,) k <$> reindexExprI e) rs
reindexExpr (TupleE es) = TupleE <$> mapM reindexExprI es
reindexExpr e = return e


-- FIXME: when I add linking to line numbers, I'll need to update that map
-- also. The trace should be recorded.
newIndex :: Int -> MorlocMonad Int
newIndex i = do
  i' <- MM.getCounter
  copyState i i'
  return i'

yIsX' :: (Ord a) => GMap a b c -> a -> a -> MorlocMonad (GMap a b c)
yIsX' m k1 k2 = case GMap.yIsX m k1 k2 of
  Nothing -> MM.throwError . CallTheMonkeys $ "Internal key error"
  (Just m') -> return m'

-- reindex
--   :: GMap Int Int [EType]
--   -> SAnno Int Many [Int]
--   -> MorlocMonad (GMap Int Int [EType], SAnno Int Many [Int])
-- reindex m (SAnno (Many xs) g) = do
--   i <- MM.getCounter
--   m' <- yIsX' m (metaId g) i
--   let g' = g {metaId = i}
--   (m'', xs') <- statefulMapM reindexSExpr m' xs
--   return (m'', SAnno (Many xs') g')
--
-- reindexSExpr
--   :: GMap Int Int [EType]
--   -> (SExpr Int Many [Int], [Int])
--   -> MorlocMonad (GMap Int Int [EType], (SExpr Int Many [Int], [Int]))
-- reindexSExpr m0 (s0, ts0) = do
--   (m', ts') <- statefulMapM reindexOne m0 ts0
--   (m'', s') <- f m' s0
--   return (m'', (s', ts'))
--   where
--   f :: GMap Int Int [EType] -> SExpr Int Many [Int] -> MorlocMonad (GMap Int Int [EType], SExpr Int Many [Int])
--   f m (AccS x t) = do
--     (m', x') <- reindex m x
--     return (m', AccS x' t)
--   f m (ListS xs) = do
--     (m', xs') <- statefulMapM reindex m xs
--     return (m', ListS xs')
--   f m (TupleS xs) = do
--     (m', xs') <- statefulMapM reindex m xs
--     return (m', TupleS xs')
--   f m (LamS v x) = do
--     (m', x') <- reindex m x
--     return (m', LamS v x')
--   f m (AppS x xs) = do
--     (m', x') <- reindex m x
--     (m'', xs') <- statefulMapM reindex m' xs
--     return (m'', AppS x' xs')
--   f m (RecS rs) = do
--     (m', xs') <- statefulMapM reindex m (map snd rs)
--     return (m', RecS (zip (map fst rs) xs'))
--   f m x = return (m, x)
--
--   reindexOne :: GMap Int Int [EType] -> Int -> MorlocMonad (GMap Int Int [EType], Int)
--   reindexOne m i = do
--     i' <- MM.getCounter
--     m' <- yIsX' m i i'
--     return (m', i')
