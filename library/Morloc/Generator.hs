{-|
Module      : Morloc.Generator
Description : Generate code from the RDF representation of a Morloc script 
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Generator (generate) where

import Xi
import Morloc.Global
import Morloc.Operators
import qualified Morloc.Language as ML
import qualified Morloc.Nexus.Nexus as MN
import qualified Morloc.Pools.Pools as MP
import qualified Morloc.Data.Text as MT
import qualified Morloc.Monad as MM

import Control.Monad.State (State, evalState, gets, get, put)
import qualified Control.Monad as CM
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.List as DL
import qualified Data.List.Extra as DLE
import qualified Data.Maybe as DM

import Debug.Trace (traceM)

generate :: [Module] -> MorlocMonad (Script, [Script])
generate mods = do
  -- root :: Module -- fail if there is not a single "root" module, e.g., main
  root <- rootModule mods 
  -- ms :: [manifold]
  -- build all manifold paths starting from exported root declarations the
  -- state monad handles scope and module attributes as well as assignment of
  -- unique integer IDs to all manifolds.
  modelState <- initProgramState mods
  let ms = evalState (makeRootManifolds root) modelState
  -- nexus :: Script
  -- generate the nexus script
  nexus <- MN.generate ms
  -- hss :: Map.Map Lang SerialMap
  hss <- makeSerialMaps mods
  -- pools :: [Script]
  pools <- MP.generate ms hss

  traceM (show ms)

  -- (Script, [Script])
  return (nexus, pools)

data Source' = Source' {
    sourcePath :: Maybe Path
  , sourceLang :: Lang
  , sourceName :: Name
  , sourceAlias :: Name
}

type Program a = State ProgramState a

data ProgramState = ProgramState {
    stateCount :: Integer
  , stateModuleSources :: Map.Map MVar (Map.Map EVar Source')
  , stateModuleExports :: Map.Map MVar (Set.Set EVar)
  , stateModuleImports :: Map.Map MVar (Map.Map EVar (MVar, EVar))
  , stateModuleDeclarations :: Map.Map MVar (Map.Map EVar Expr)
  , stateModuleTypeSetMap :: Map.Map MVar (Map.Map EVar TypeSet)
  , stateModuleMap :: Map.Map MVar Module
}

initProgramState :: [Module] -> MorlocMonad ProgramState
initProgramState mods = do
  -- typesetmap :: Map.Map MVar (Map.Map EVar TypeSet)
  -- all type information within each module (no inheritance) is collected into
  -- one TypeSet object (TypeSet (Maybe EType) [EType]), where the [EType] list
  -- stores all realizations and the (Maybe EType) is the general type. This
  -- information may be stored across multiple signatures and declarations.
  let typmap = makeTypeSetMap mods
  return $ ProgramState {
        stateCount = 0 -- counter used to create manifold IDs
      , stateModuleSources      = lmap mksrcmap mods -- \
      , stateModuleExports      = lmap mkexpmap mods -- |  These are all global
      , stateModuleImports      = lmap mkimpmap mods --  \ constructs that can
      , stateModuleDeclarations = lmap mkdecmap mods --  / be  used anywhere
      , stateModuleTypeSetMap   = typmap             -- |
      , stateModuleMap          = modmap             -- /
    }
  where
    lmap f ms = Map.fromList $ map (\m -> (moduleName m, f m)) ms

    mksrcmap :: Module -> Map.Map EVar Source'
    mksrcmap m = Map.unions $ map (\(SrcE x y z) -> makeSource (ML.readLangName x) y z) (moduleBody m)

    mkexpmap :: Module -> Set.Set EVar
    mkexpmap m = Set.fromList (moduleExports m)

    mkimpmap :: Module -> Map.Map EVar (MVar, EVar)
    mkimpmap m = Map.fromList [(alias, (mv, ev)) | (mv, ev, alias) <- moduleImports m]

    mkdecmap :: Module -> Map.Map EVar Expr
    mkdecmap m = Map.fromList [(v, e) | (Declaration v e) <- moduleBody m]

    modmap = Map.fromList [(moduleName m, m) | m <- mods]

getId :: Program Integer
getId = do
  s <- get
  let i = stateCount s
  put (s {stateCount = i + 1})
  return i

makeTypeSetMap :: [Module] -> Map.Map MVar (Map.Map EVar TypeSet)
makeTypeSetMap mods = Map.fromList [(moduleName m, findSignatures m) | m <- mods]

modExports :: MVar -> Program (Set.Set EVar)
modExports v = fmap (Map.findWithDefault Set.empty v) (gets stateModuleExports)

modDeclarations :: MVar -> Program (Map.Map EVar Expr)
modDeclarations v = fmap (Map.findWithDefault Map.empty v) (gets stateModuleDeclarations)

lookupImport :: MVar -> EVar -> Program (Maybe (MVar, EVar))
lookupImport m e = do
  impmap <- gets stateModuleImports
  return $ Map.lookup m impmap >>= Map.lookup e

lookupTypeSet :: MVar -> EVar -> Program (Maybe TypeSet)
lookupTypeSet mv ev = do
  ts <- gets stateModuleTypeSetMap
  return $ Map.lookup mv ts >>= Map.lookup ev

-- searches the import tree for existence of a declaration
isDeclared :: MVar -> EVar -> Program Bool
isDeclared m e = do
  modmap <- gets stateModuleMap
  decmap <- gets stateModuleDeclarations
  imp <- lookupImport m e
  case (fmap (Map.member e) (Map.lookup m decmap), imp) of
    (Just _, _) -> return True
    (Nothing, Nothing) -> return False
    (Nothing, Just (m', e')) -> isDeclared m' e'

makeRootManifolds :: Module -> Program [Manifold]
makeRootManifolds m = do
  exports <- modExports (moduleName m)
  declarations <- modDeclarations (moduleName m)
  fmap (concat . Map.elems)
    . Map.traverseWithKey (nexusManifolds m)
    $ Map.restrictKeys declarations exports

nexusManifolds
  :: Module
  -> EVar
  -> Expr
  -> Program [Manifold]
nexusManifolds m ev@(EV v) (AnnE e@(LamE _ _) gentype) = do
  t <- lookupTypeSet (moduleName m) ev
  i <- getId
  case (uncurryExpr e, t) of
    ((_, _, []), _) -> error $ "nexus can only accept applications in declarations: "
                             <> show v <> " :: " <> show e
    (_, Nothing) -> error "no signature found for this type"
    (_, Just (TypeSet Nothing _)) -> error "no general type"
    ((vars, f, es), Just (TypeSet (Just e) rs)) -> do
      args <- CM.zipWithM (exprAsArgument vars m) [0..] es
      return . (flip (:)) (concat . map snd $ args) $ Manifold
        { mid = i
        , mCallId = makeURI (moduleName m) i
        , mAbstractType = Just (etype2mtype v (e {etype = gentype}))
        , mRealizations = map (toRealization v m) rs
        , mMorlocName = v
        , mExported = True
        , mCalled = False
        , mDefined = True
        , mComposition = Just v
        , mBoundVars = [v' | (EV v') <- vars]
        , mArgs = map fst args
        }
nexusManifolds _ _ _ = error "I can only export functions from nexus, sorry :("

exprAsArgument
  :: [EVar]
  -> Module
  -> Int -- ^ 0-indexed position of the argument
  -> Expr
  -> Program (Argument, [Manifold])
exprAsArgument bnd _ p (AnnE (VarE v@(EV v')) t)
  | elem v bnd = return (ArgName v', [])
  | otherwise = return (ArgNest v', [])
exprAsArgument bnd m _ (AnnE (AppE e1 e2) t) = case uncurryApplication e1 e2 of
  (f, es) -> do
    let v@(EV mname) = exprAsFunction f
    ms <- gets stateModuleMap
    ts <- gets stateModuleTypeSetMap
    defined <- isDeclared (moduleName m) v
    i <- getId
    case lookupVar v ts ms m of
      (TypeSet Nothing _) -> error "ah fuck shit"
      (TypeSet (Just etyp) rs) -> do
        args <- CM.zipWithM (exprAsArgument bnd m) [0..] es
        let newManifold = Manifold {
              mid = i
            , mCallId = makeURI (moduleName m) i
            , mAbstractType = Just (etype2mtype mname (etyp {etype = t}))
            , mRealizations = map (toRealization mname m) rs
            , mMorlocName = mname -- TODO: really?
            , mExported = elem v (moduleExports m)
            , mCalled = True
            , mDefined = defined
            , mComposition = Nothing -- TODO: are you sure?
            , mBoundVars = [b | (EV b) <- bnd]
            , mArgs = map fst args
          }
        return (  ArgCall (makeURI (moduleName m) i)
                , newManifold : (concat . map snd $ args))
-- ArgData primitives
exprAsArgument _ _ _ (AnnE x@(NumE   _) _) = return (ArgData $ primitive2mdata x, [])
exprAsArgument _ _ _ (AnnE x@(LogE   _) _) = return (ArgData $ primitive2mdata x, [])
exprAsArgument _ _ _ (AnnE x@(StrE   _) _) = return (ArgData $ primitive2mdata x, [])
exprAsArgument _ _ _ (AnnE x@(ListE  _) _) = return (ArgData $ primitive2mdata x, [])
exprAsArgument _ _ _ (AnnE x@(TupleE _) _) = return (ArgData $ primitive2mdata x, [])
exprAsArgument _ _ _ (AnnE x@(RecE   _) _) = return (ArgData $ primitive2mdata x, [])
-- errors
exprAsArgument _ _ _ (AnnE (LamE _ _) (FunT _ _)) = error "lambdas not yet supported"
exprAsArgument _ _ _ _ = error "expected annotated expression"

makeURI :: MVar -> Integer -> URI
makeURI (MV v) i = URI $ v <> "_" <> MT.show' i

exprAsFunction :: Expr -> EVar
exprAsFunction (VarE v) = v
exprAsFunction (AnnE (VarE v) _) = v
exprAsFunction e = error $ "I'm sorry man, I can only handle VarE, not this: " <> show e 

-- TODO: allow anything inside a container
primitive2mdata :: Expr -> MData
primitive2mdata (AnnE t _) = primitive2mdata t
primitive2mdata (NumE x) = Num' (MT.show' x)
primitive2mdata (LogE x) = Log' x
primitive2mdata (StrE x) = Str' x
primitive2mdata (ListE es) = Lst' $ map primitive2mdata es
primitive2mdata (TupleE es) = Lst' $ map primitive2mdata es
primitive2mdata (RecE xs) = Rec' $ map entry xs where
  entry :: (EVar, Expr) -> (Name, MData)
  entry (EV v, e) = (v, primitive2mdata e)
primitive2mdata _ = error "complex stuff is not yet allowed in MData (coming soon)"

toRealization :: Name -> Module -> EType -> Realization
toRealization n m e@(EType t (Just langText) props _ (Just (Just f, EV srcname))) =
  case ML.readLangName langText of 
    (Just lang) -> Realization
      { rLang = lang
      , rName = srcname
      , rConcreteType = Just $ etype2mtype n e
      , rModulePath = modulePath m
      , rSourcePath = Just f
      , rSourced = True
      }
    Nothing -> error "unrecognized language"
toRealization _ _ _ = error "This is not a realization"

-- | uncurry one level of an expression, pulling out a tuple with
-- (<lambda-args>, <application-base>, <application-args>)
-- Examples:
-- @5@              ==> ([], 5, [])
-- @f a b@          ==> ([], f, [a,b])
-- @f a b = g 4 a b ==> ([a,b], g, [4,a,b])
-- @f x = g (h x) 5 ==> ([x], g, [(h x), 5]  -- no recursion into expressions
uncurryExpr :: Expr -> ([EVar], Expr, [Expr])
uncurryExpr (LamE v e) = (\(vs, e', es) -> (v:vs, e', es)) (uncurryExpr e)
uncurryExpr (AnnE (AppE e1 e2) _) = (\(e, es) -> ([], e, es)) (uncurryApplication e1 e2)
uncurryExpr (AppE e1 e2) = (\(e, es) -> ([], e, es)) (uncurryApplication e1 e2)
uncurryExpr e = ([], e, [])

-- | uncurry an application
-- Examples:
-- @f x@  ==> (f, [x])
-- @f x (g y)@  ==> (f, [x, (g y)])  -- no recursion
uncurryApplication
  :: Expr -- "base" of an application (e.g., @f@ in @f x@)
  -> Expr -- argument in an application (e.g., @x@ in @f x@)
  -> (Expr, [Expr])
uncurryApplication (AppE e1 e2) e0 = onSnd ((flip (++)) [e0]) (uncurryApplication e1 e2)
uncurryApplication (AnnE (AppE e1 e2) _) e0 = onSnd ((flip (++)) [e0]) (uncurryApplication e1 e2)
uncurryApplication f en = (f, [en])

onSnd :: (b -> c) -> (a, b) -> (a, c)
onSnd f (x, y) = (x, f y)

onFst :: (a -> c) -> (a, b) -> (c, b)
onFst f (x, y) = (f x, y)

makeSource :: Maybe Lang -> Maybe Filename -> [(EVar, EVar)] -> Map.Map EVar Source'
makeSource (Just l) f xs = Map.fromList $ map (\(EV n, EV a) -> (EV a, Source' f l n a)) xs
makeSource Nothing _ _ = error "unsupported language"

rootModule :: [Module] -> MorlocMonad Module
rootModule ms = case roots of
  [root] -> return root
  [] -> MM.throwError . GeneratorError $ "cyclic dependency"
  _ -> MM.throwError . GeneratorError $ "expected a unique root"
  where
    mset = Set.fromList . concat $ [[n | (n,_,_) <- moduleImports m] | m <- ms]
    roots = filter (\m -> not $ Set.member (moduleName m) mset) ms

makeSerialMaps :: [Module] -> MorlocMonad (Map.Map Lang SerialMap)
makeSerialMaps (concat . map moduleBody -> es)
  = fmap (
      Map.mapWithKey toSerialMap -- Map Lang SerialMap
    . Map.fromList               -- Map Lang [Expr]
    . DLE.groupSort              -- [(Lang, [Expr])]
    . DM.catMaybes
  ) $ mapM f es  -- MorloMonad [Maybe (Lang, Expr)]
  where
    -- collect all sources and signatures paired with language
    -- needed for @toSerialMap@
    -- convert textual language names to Lang's
    f :: Expr -> MorlocMonad (Maybe (Lang, Expr))
    f e@(SrcE l _ _) = case ML.readLangName l of
      (Just lang) -> return $ Just (lang, e)
      _ -> MM.throwError . GeneratorError $ "unrecognized language: " <> l
    f e@(Signature _ (elang -> Just l)) = case ML.readLangName l of
      (Just lang) -> return $ Just (lang, e)
      _ -> MM.throwError . GeneratorError $ "unrecognized language: " <> l
    f _ = return $ Nothing

    toSerialMap :: Lang -> [Expr] -> SerialMap
    toSerialMap lang es = SerialMap {
        serialLang = lang
      , serialPacker = Map.fromList [(etype2mtype n e, n)
                                    | (Signature (EV n) e) <- es
                                    , Set.member Pack (eprop e)]
      , serialUnpacker = Map.fromList [(etype2mtype n e, n)
                                      | (Signature (EV n) e) <- es
                                      , Set.member Unpack (eprop e)]
      , serialSources = DL.nub [p | (SrcE _ (Just p) _) <- es]
      }

etype2mtype :: Name -> EType -> MType
etype2mtype n e = type2mtype Set.empty (etype e) where

  meta = MTypeMeta {
      metaName = Just n
    , metaProp = map prop2text (Set.toList (eprop e))
    , metaLang = elang e >>= ML.readLangName
  }

  prop2text Pack = ["pack"]
  prop2text Unpack = ["unpack"]
  prop2text Cast = ["cast"]
  prop2text (GeneralProperty ts) = ts

  type2mtype :: Set.Set Name -> Type -> MType
  type2mtype bnds (VarT (TV v))
    | Set.member v bnds = MAbstType meta v []
    | otherwise = MConcType meta v []
  type2mtype _ (ExistT _) = error "found existential type"
  type2mtype bnds (Forall (TV v) t) = (type2mtype (Set.insert v bnds) t)
  type2mtype bnds (FunT t1 t2) =
    let ts = type2mtype bnds t1 : functionTypes bnds t2
    in MFuncType meta (init ts) (last ts)
  type2mtype bnds (ArrT (TV v) ts)
    | Set.member v bnds = error $ "currently I can't use bound variables in ArrT"
    | otherwise = MAbstType meta v (map (type2mtype bnds) ts)
  type2mtype bnds (RecT fs) = MConcType meta "Record" (map (recordEntry bnds) fs)
  type2mtype _ t = error $ "cannot cast type: " <> show t

  recordEntry :: Set.Set Name -> (TVar, Type) -> MType
  recordEntry bnds (TV v, t)
    = MConcType meta "RecordEntry" [MConcType meta "Str" [], type2mtype bnds t]

  functionTypes :: Set.Set Name -> Type -> [MType]
  functionTypes bnds (FunT t1 t2) = type2mtype bnds t1 : functionTypes bnds t2
  functionTypes bnds t = [type2mtype bnds t]

-- | Lookup a variable in a given module. If collect any type information
-- (including realizations). Whether the variable is found or not, recurse into
-- all imported modules searching through exported variables for additional
-- signatures describing the variable. Collect all information in the returned
-- TypeSet object. Die if there is disagreement about the basic general type.
lookupVar
  :: EVar
  -> Map.Map MVar (Map.Map EVar TypeSet)
  -> Map.Map MVar Module
  -> Module
  -> TypeSet
lookupVar v typesetmap modulemap m = case Map.lookup (moduleName m) typesetmap >>= Map.lookup v of
  Nothing -> foldr (joinTypeSet const) (TypeSet Nothing []) ts
  (Just t) -> foldr (joinTypeSet const) t ts
  where
    ts = [maybe (TypeSet Nothing []) id (fmap (lookupVar v' typesetmap modulemap) $ Map.lookup mv' modulemap)
         | (mv', v', alias') <- moduleImports m
         , v == alias']

-- | collect all type information within a module
-- first all signatures are collected, storing each realization
-- then the
findSignatures :: Module -> Map.Map EVar TypeSet
findSignatures (moduleBody -> es)
  = foldr insertAppendEtype (
        Map.map (foldr appendTypeSet (TypeSet Nothing []))
      . Map.fromList
      . DLE.groupSort
      $ [(v, t) | (Signature v t) <- es]
    ) [(v, type2etype t) | (AnnE (Declaration v _) t) <- es]

type2etype :: Type -> EType
type2etype t = EType
  { etype = t
  , elang = Nothing
  , eprop = Set.empty
  , econs = Set.empty
  , esource = Nothing
  }

insertAppendEtype :: (EVar, EType) -> Map.Map EVar TypeSet -> Map.Map EVar TypeSet
insertAppendEtype (v, t) = Map.insertWith (joinTypeSet f) v (TypeSet (Just t) []) where
  f edec eold = eold { etype = etype edec }

appendTypeSet :: EType -> TypeSet -> TypeSet
appendTypeSet e@(elang -> Nothing) (TypeSet _ es) = TypeSet (Just e) es
appendTypeSet e (TypeSet x es) = TypeSet x (e:es)

joinTypeSet :: (EType -> EType -> EType) -> TypeSet -> TypeSet -> TypeSet
joinTypeSet f (TypeSet g1 es1) (TypeSet g2 es2)
  = foldr appendTypeSet (TypeSet (xor f g1 g2) es1) es2

xor :: (a -> a -> a) -> Maybe a -> Maybe a -> Maybe a
xor _ (Just x) Nothing = Just x
xor _ Nothing (Just x) = Just x
xor f (Just x) (Just y) = Just (f x y)
xor _ _ _ = Nothing
