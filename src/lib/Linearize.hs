-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module Linearize (linearize) where

import Control.Category ((>>>))
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.Functor
import Data.List (elemIndex)
import Data.Maybe (catMaybes, isJust)
import qualified Data.Set as S
import GHC.Stack

import Builder
import Core
import CheapReduction
import IRVariants
import MTL1
import Name
import Subst
import {-# SOURCE #-} Simplify (linearizeTopFun)
import PPrint
import QueryType
import Types.Core
import Types.Primitives
import Util (bindM2, enumerate)

-- === linearization monad ===

data ActivePrimals (n::S) = ActivePrimals
  { activeVars    :: [AtomName SimpIR n]  -- includes refs and regions
  , activeEffs    :: EffectRow SimpIR n }

emptyActivePrimals :: ActivePrimals n
emptyActivePrimals = ActivePrimals [] Pure

data TangentArgs (n::S) = TangentArgs [SAtomName n]

type PrimalM  = SubstReaderT Name (ReaderT1 ActivePrimals (DoubleBuilder SimpIR)) :: MonadKind2
type TangentM = ReaderT1 TangentArgs (DoubleBuilder SimpIR) :: MonadKind1

data WithTangent (n::S) (e1::E) (e2::E) =
  WithTangent (e1 n) (forall l. (Emits l, DExt n l) => TangentM l (e2 l))

type LinM i o e1 e2 = PrimalM i o (WithTangent o e1 e2)

-- TODO: maybe we shouldn't roll subst into this
pureLin :: (RenameE e, SinkableE e) => e i -> LinM i o e e
pureLin x = do
  x' <- renameM x
  return $ WithTangent x' (sinkM x')

runPrimalM :: Subst Name i o -> ActivePrimals o -> PrimalM i o a -> DoubleBuilder SimpIR o a
runPrimalM subst args cont = runReaderT1 args $ runSubstReaderT subst cont

activePrimalIdx :: AtomName SimpIR o -> PrimalM i o (Maybe Int)
activePrimalIdx v = asks \primals -> elemIndex v (activeVars primals)

getActivePrimals :: PrimalM i o (ActivePrimals o)
getActivePrimals = ask

extendActiveSubst
  :: BindsAtMostOneName b (AtomNameC SimpIR)
  => b i i' -> AtomName SimpIR o -> PrimalM i' o a -> PrimalM i o a
extendActiveSubst b v cont = extendSubst (b@>v) $ extendActivePrimals v cont

extendActiveEffs :: Effect SimpIR o -> PrimalM i o a -> PrimalM i o a
extendActiveEffs eff = local \primals ->
  primals { activeEffs = extendEffRow (eSetSingleton eff) (activeEffs primals)}

extendActivePrimals :: AtomName SimpIR o -> PrimalM i o a -> PrimalM i o a
extendActivePrimals v =
  local \primals -> primals { activeVars = activeVars primals ++ [v] }

getTangentArg :: Int -> TangentM o (Atom SimpIR o)
getTangentArg idx = asks \(TangentArgs vs) -> Var $ vs !! idx

extendTangentArgs :: SAtomName n -> TangentM n a -> TangentM n a
extendTangentArgs v m = local (\(TangentArgs vs) -> TangentArgs $ vs ++ [v]) m

extendTangentArgss :: [SAtomName n] -> TangentM n a -> TangentM n a
extendTangentArgss vs' m = local (\(TangentArgs vs) -> TangentArgs $ vs ++ vs') m

getTangentArgs :: TangentM o (TangentArgs o)
getTangentArgs = ask

bindLin
  :: Emits o
  => LinM i o e  e
  -> (forall o' m. (Emits o', DExt o o', Builder SimpIR m) => e o' -> m o' (e' o'))
  -> LinM i o e' e'
bindLin m f = do
  result <- m
  withBoth result f

withBoth
  :: Emits o
  => WithTangent o e e
  -> (forall o' m. (Emits o', DExt o o', Builder SimpIR m) => e o' -> m o' (e' o'))
  -> PrimalM i o (WithTangent o e' e')
withBoth (WithTangent x tx) f = do
  Distinct <- getDistinct
  y <- f x
  return $ WithTangent y do
    tx >>= f

_withTangentComputation
  :: Emits o
  => WithTangent o e1 e2
  -> (forall o' m. (Emits o', DExt o o', Builder SimpIR m) => e2 o' -> m o' (e2' o'))
  -> PrimalM i o (WithTangent o e1 e2')
_withTangentComputation (WithTangent x tx) f = do
  Distinct <- getDistinct
  return $ WithTangent x do
    tx >>= f

fmapLin
  :: Emits o
  => (forall o'. e o' -> e' o')
  -> LinM i o e  e
  -> LinM i o e' e'
fmapLin f m = m `bindLin` (pure . f)

zipLin :: LinM i o e1 e1 -> LinM i o e2 e2 -> LinM i o (PairE e1 e2) (PairE e1 e2)
zipLin m1 m2 = do
  WithTangent x1 t1 <- m1
  WithTangent x2 t2 <- m2
  return $ WithTangent (PairE x1 x2) do PairE <$> t1 <*> t2

seqLin
  :: Traversable f
  => f (LinM i o e e)
  -> LinM i o (ComposeE f e) (ComposeE f e)
seqLin ms = do
  ms' <- sequence ms
  let xs = ms' <&> \(WithTangent x _) -> x
  return $ WithTangent (ComposeE xs) do
    ComposeE <$> forM ms' \(WithTangent _ t) -> t

liftTangentM :: TangentArgs o -> TangentM o a -> PrimalM i o a
liftTangentM args m = liftSubstReaderT $ lift11 $ runReaderT1 args m

isTrivialForAD :: SExpr o -> PrimalM i o Bool
isTrivialForAD expr = do
  trivialTy  <- presentAnd isSingletonType <$> (maybeTangentType =<< getType expr)
  hasActiveEffs <- getEffects expr >>= \case
                     Pure -> return False
                     -- TODO: Be more precise here, such as checking
                     -- whether the effects are themselves active.
                     _ -> return True
  hasActiveVars <- isActive expr
  return $ not hasActiveEffs && (trivialTy || not hasActiveVars)
    where presentAnd :: (a -> Bool) -> Maybe a -> Bool
          presentAnd = any

isActive :: HoistableE e => e o -> PrimalM i o Bool
isActive e = do
  vs <- (S.fromList . activeVars) <$> getActivePrimals
  return $ any (`S.member` vs) (freeAtomVarsList e)

-- === converision between monadic and reified version of functions ===

tangentFunAsLambda
  :: Emits o
  => (forall o'. (DExt o o', Emits o') => TangentM o' (Atom SimpIR o'))
  -> PrimalM i o (SLam o)
tangentFunAsLambda cont = do
  ActivePrimals primalVars _ <- getActivePrimals
  tangentTys <- getTangentArgTys primalVars
  buildNaryLamExpr tangentTys \tangentVars -> do
    liftTangentM (TangentArgs $ map sink tangentVars) cont

getTangentArgTys :: (Fallible1 m, EnvExtender m) => [SAtomName n] -> m n (EmptyAbs (Nest SBinder) n)
getTangentArgTys topVs = go mempty topVs where
  go :: (Fallible1 m, EnvExtender m)
     => EMap SAtomName SAtomName n -> [SAtomName n] -> m n (EmptyAbs (Nest SBinder) n)
  go _ [] = return $ EmptyAbs Empty
  go heapMap (v:vs) = getType v >>= \case
    -- This is a hack to handle heaps/references. They normally come in pairs
    -- like this, but there's nothing to prevent users writing programs that
    -- sling around heap variables by themselves. We should try to do something
    -- better...
    TC HeapType -> do
      withFreshBinder (getNameHint v) (TC HeapType) \hb -> do
        let newHeapMap = sink heapMap <> eMapSingleton (sink v) (binderName hb)
        Abs bs UnitE <- go newHeapMap $ sinkList vs
        return $ EmptyAbs $ Nest (hb:>TC HeapType) bs
    RefTy (Var h) referentTy -> do
      case lookupEMap heapMap h of
        Nothing -> error "shouldn't happen?"
        Just h' -> do
          tt <- tangentType referentTy
          let refTy = RefTy (Var h') tt
          withFreshBinder (getNameHint v) refTy \refb -> do
            Abs bs UnitE <- go (sink heapMap) $ sinkList vs
            return $ EmptyAbs $ Nest (refb:>refTy) bs
    ty -> do
      tt <- tangentType ty
      withFreshBinder (getNameHint v) tt \b -> do
        Abs bs UnitE <- go (sink heapMap) $ sinkList vs
        return $ EmptyAbs $ Nest (b:>tt) bs

-- tangent lambda
type LinLam = SLam
-- tangent lambda prefixed by residual args
type LinLamAbs = ReconAbs SimpIR LinLam
-- tangent lambda prefixed by residual args, then further prefixed by lambda binders
-- (e.g. the `i` binder in a `for`)
type LinLamAbsAbs = Abs (Nest SBinder) LinLamAbs

linearizeBlockDefunc :: SBlock i -> PrimalM i o (SBlock o, LinLamAbs o)
linearizeBlockDefunc = linearizeBlockDefuncGeneral emptyOutFrag

linearizeBlockDefuncGeneral :: ScopeFrag o' o -> SBlock i -> PrimalM i o (SBlock o, LinLamAbs o')
linearizeBlockDefuncGeneral locals block = do
  Abs decls result <- buildScoped do
    WithTangent primalResult tangentFun <- linearizeBlock block
    lam <- tangentFunAsLambda tangentFun
    return $ PairE primalResult lam
  (blockAbs, recon) <- refreshAbs (Abs decls result) \decls' (PairE primal lam) -> do
    (residuals, recon) <- telescopicCapture (locals >>> toScopeFrag decls') lam
    return (Abs decls' (PairVal primal residuals), recon)
  block' <- makeBlockFromDecls blockAbs
  return (block', recon)

-- Inverse of tangentFunAsLambda. Should be used inside a returned tangent action.
_applyLinLam :: Emits n => SLam n -> TangentM n (Atom SimpIR n)
_applyLinLam (LamExpr bs body) = do
  TangentArgs args <- getTangentArgs
  applyRename (bs @@> args) body >>= emitBlock

applyLinLamAbs :: Emits n => LinLamAbs n -> SAtom n -> TangentM n (Atom SimpIR n)
applyLinLamAbs (Abs bsRecon (LamExpr bs body)) residuals = do
  residualss <- unpackTelescope residuals
  TangentArgs args <- getTangentArgs
  applySubst (    bsRecon @@> map SubstVal residualss
              <.> bs      @@> map Rename args) body >>= emitBlock

applyLinLamAbsAbs :: Emits n => LinLamAbsAbs n -> [SAtom n] -> SAtom n -> TangentM n (Atom SimpIR n)
applyLinLamAbsAbs (Abs bsLam (Abs bsRecon (LamExpr bs body))) lamArgs residuals = do
  residualss <- unpackTelescope residuals
  TangentArgs args <- getTangentArgs
  applySubst (    bsLam   @@> map SubstVal lamArgs
              <.> bsRecon @@> map SubstVal residualss
              <.> bs      @@> map Rename args) body >>= emitBlock

-- === actual linearization passs ===

-- main API entrypoint
linearize :: Emits n => SLam n -> SAtom n -> DoubleBuilder SimpIR n (SAtom n, SLam n)
linearize f x = do
  runPrimalM idSubst emptyActivePrimals $
    linearizeLambdaApp f x
{-# SCC linearize #-}

-- reify the tangent builder as a lambda
linearizeLambdaApp :: Emits o => SLam i -> SAtom o -> PrimalM i o (SAtom o, SLam o)
linearizeLambdaApp (UnaryLamExpr b body) x = do
  vp <- emitAtomToName noHint x
  extendActiveSubst b vp do
    WithTangent primalResult tangentAction <- linearizeBlock body
    tanFun <- tangentFunAsLambda tangentAction
    return (primalResult, tanFun)
linearizeLambdaApp _ _ = error "not implemented"

linearizeAtom :: Emits o => Atom SimpIR i -> LinM i o SAtom SAtom
linearizeAtom atom = case atom of
  Var v -> do
    v' <- renameM v
    activePrimalIdx v' >>= \case
      Nothing -> withZeroT $ return (Var v')
      Just idx -> return $ WithTangent (Var v') $ getTangentArg idx
  Con con -> linearizePrimCon con
  DepPair _ _ _     -> notImplemented
  TabPi _         -> emitZeroT
  DepPairTy _     -> emitZeroT
  TC _            -> emitZeroT
  PtrVar _        -> emitZeroT
  ProjectElt i x -> do
    WithTangent x' tx <- linearizeAtom x
    xi <- normalizeProj i x'
    return $ WithTangent xi do
      t <- tx
      normalizeProj i t
  RepValAtom _ -> emitZeroT
  where emitZeroT = withZeroT $ renameM atom

linearizeBlock :: Emits o => SBlock i -> LinM i o SAtom SAtom
linearizeBlock (Block _ decls result) =
  linearizeDecls decls $ linearizeAtom result

linearizeDecls :: Emits o => Nest SDecl i i' -> LinM i' o e1 e2 -> LinM i  o e1 e2
linearizeDecls Empty cont = cont
-- TODO: as an optimization, don't bother extending the tangent args if the
-- tangent is trivial, either because its type is a singleton or because there
-- are no active vars.
linearizeDecls (Nest (Let b (DeclBinding ann _ expr)) rest) cont = do
  expr' <- renameM expr
  isTrivialForAD expr' >>= \case
    True -> do
      v <- emit expr'
      extendSubst (b@>v) $ linearizeDecls rest cont
    False -> do
      WithTangent p tf <- linearizeExpr expr
      v <- emitDecl (getNameHint b) ann (Atom p)
      extendActiveSubst b v do
        WithTangent pRest tfRest <- linearizeDecls rest cont
        return $ WithTangent pRest do
          t <- tf
          vt <- emitDecl (getNameHint b) ann (Atom t)
          extendTangentArgs vt $
            tfRest

linearizeExpr :: Emits o => SExpr i -> LinM i o SAtom SAtom
linearizeExpr expr = case expr of
  Atom x -> linearizeAtom x
  TopApp f xs -> do
    (xs', ts) <- unzip <$> forM xs \x -> do
      x' <- renameM x
      isActive x' >>= \case
        True  -> do
          WithTangent x'' t <- dropSubst $ linearizeAtom x'
          return (x'', Just (WithTangent (unitLike x'') t))
        False -> return (x', Nothing)
    f' <- renameM f
    -- TODO(dougalm): this works, but I think that what we really want here is
    -- to hoist the argument to `linearizeTopFun`, rather than the result. We
    -- want to pop all the way up to the top level, hoisting the E-kinded
    -- `LinearizationSpec` with us, rather than working underneath all the local
    -- bindings and then only hoisting the final result.
    Just (PairE fPrimal fTan) <- liftTopBuilderAndEmit $
       liftM toPairE $ linearizeTopFun (sink $ LinearizationSpec f' (map isJust ts))
    (ans, residuals) <- fromPair =<< naryTopApp fPrimal xs'
    return $ WithTangent ans do
      ts' <- forM (catMaybes ts) \(WithTangent UnitE t) -> t
      naryTopApp (sink fTan) (sinkList xs' ++ [sink residuals] ++ ts')
    where
      unitLike :: e n -> UnitE n
      unitLike _ = UnitE
  TabApp x idxs -> do
    zipLin (linearizeAtom x) (pureLin $ ListE $ toList idxs) `bindLin`
      \(PairE x' (ListE idxs')) -> naryTabApp x' idxs'
  PrimOp op      -> linearizeOp op
  RefOp ref m -> case m of
    MAsk -> linearizeAtom ref `bindLin` \ref' -> liftM Var $ emit $ RefOp ref' MAsk
    MExtend monoid x -> do
      -- TODO: check that we're dealing with a +/0 monoid
      monoid' <- renameM monoid
      zipLin (linearizeAtom ref) (linearizeAtom x) `bindLin` \(PairE ref' x') ->
        liftM Var $ emit $ RefOp ref' $ MExtend (sink monoid') x'
    MGet   -> linearizeAtom ref `bindLin` \ref' -> liftM Var $ emit $ RefOp ref' MGet
    MPut x -> zipLin (linearizeAtom ref) (linearizeAtom x) `bindLin` \(PairE ref' x') ->
                liftM Var $ emit $ RefOp ref' $ MPut x'
    IndexRef i -> zipLin (la ref) (pureLin i) `bindLin`
                    \(PairE ref' i') -> emitExpr $ RefOp ref' $ IndexRef i'
    ProjRef i -> la ref `bindLin` \ref' -> emitExpr $ RefOp ref' $ ProjRef i
  Hof e      -> linearizeHof e
  Case e alts resultTy effs -> do
    e' <- renameM e
    effs' <- renameM effs
    resultTy' <- renameM resultTy
    isActive e' >>= \case
      True -> notImplemented
      False -> do
        (alts', residualTys, recons) <- unzip3 <$> buildCaseAlts e' \i b' -> do
          Abs b body <- return $ alts !! i
          extendSubst (b@>binderName b') do
            (block, linLam) <- linearizeBlockDefuncGeneral (toScopeFrag b') body
            PairTy _ residualTy <- getType block
            let residualTy' = ignoreHoistFailure $ hoist b' residualTy
            return (Abs b' block, residualTy', linLam)
        alts'' <- forM (enumerate alts') \(i, alt) -> do
          injectAltResult residualTys i alt
        let fullResultTy = PairTy resultTy' (SumTy residualTys)
        (ans, residualss) <- fromPair =<< (emitExpr $ Case e' alts'' fullResultTy effs')
        resultTangentType <- tangentType resultTy'
        return $ WithTangent ans do
          buildCase (sink residualss) (sink resultTangentType) \i residuals ->
            applyLinLamAbs (sink $ recons!!i) residuals
  TabCon ty xs -> do
    ty' <- renameM ty
    seqLin (map linearizeAtom xs) `bindLin` \(ComposeE xs') ->
      emitExpr $ TabCon (sink ty') xs'
  DAMOp _        -> error "shouldn't occur here"
  where
    la = linearizeAtom

linearizeOp :: Emits o => PrimOp (Atom SimpIR i) -> LinM i o SAtom SAtom
linearizeOp op = case op of
  UnOp  uop x       -> linearizeUnOp  uop x
  BinOp bop x y     -> linearizeBinOp bop x y
  -- XXX: This assumes that pointers are always constants
  MemOp _      -> emitZeroT
  MiscOp miscOp -> linearizeMiscOp miscOp
  VectorOp _ -> error "not implemented"
  where
    emitZeroT = withZeroT $ liftM Var $ emit =<< renameM (PrimOp op)

linearizeMiscOp :: Emits o => MiscOp (Atom SimpIR i) -> LinM i o SAtom SAtom
linearizeMiscOp op = case op of
  SumTag _     -> emitZeroT
  ToEnum _ _   -> emitZeroT
  Select p t f -> (pureLin p `zipLin` la t `zipLin` la f) `bindLin`
                     \(p' `PairE` t' `PairE` f') -> emitOp $ MiscOp $ Select p' t' f'
  CastOp t v -> do
    vt <- getType =<< renameM v
    t' <- renameM t
    vtTangentType <- tangentType vt
    tTangentType  <- tangentType t'
    ((&&) <$> (vtTangentType `alphaEq` vt)
          <*> (tTangentType  `alphaEq` t')) >>= \case
      True -> do
        linearizeAtom v `bindLin` \v' -> emitOp $ MiscOp $ CastOp (sink t') v'
      False -> do
        WithTangent x xt <- linearizeAtom v
        yt <- case (vtTangentType, tTangentType) of
          (_     , UnitTy) -> return $ UnitVal
          (UnitTy, tt    ) -> zeroAt tt
          _                -> error "Expected at least one side of the CastOp to have a trivial tangent type"
        y <- emitOp $ MiscOp $ CastOp t' x
        return $ WithTangent y do xt >> return (sink yt)
  BitcastOp _ _    -> notImplemented
  UnsafeCoerce _ _ -> notImplemented
  GarbageVal _     -> notImplemented
  ThrowException _ -> notImplemented
  ThrowError _     -> emitZeroT
  OutputStream     -> emitZeroT
  ShowAny _ -> error "Shouldn't have ShowAny in simplified IR"
  ShowScalar _ -> error "Shouldn't have ShowScalar in simplified IR"
  where
    emitZeroT = withZeroT $ liftM Var $ emit =<< renameM (PrimOp $ MiscOp op)
    la = linearizeAtom

linearizeUnOp :: Emits o => UnOp -> Atom SimpIR i -> LinM i o SAtom SAtom
linearizeUnOp op x' = do
  WithTangent x tx <- linearizeAtom x'
  let emitZeroT = withZeroT $ emitOp $ UnOp op x
  case op of
    Exp    -> do
      y <- emitUnOp Exp x
      return $ WithTangent y (bindM2 mul tx (sinkM y))
    Exp2   -> notImplemented
    Log    -> withT (emitUnOp Log x) $ (tx >>= (`div'` sink x))
    Log2   -> notImplemented
    Log10  -> notImplemented
    Log1p  -> notImplemented
    Sin    -> withT (emitUnOp Sin x) $ bindM2 mul tx (emitUnOp Cos (sink x))
    Cos    -> withT (emitUnOp Cos x) $ bindM2 mul tx (neg =<< emitUnOp Sin (sink x))
    Tan    -> notImplemented
    Sqrt   -> do
      y <- emitUnOp Sqrt x
      return $ WithTangent y do
        denominator <- bindM2 mul (2 `fLitLike` sink y) (sinkM y)
        bindM2 div' tx (pure denominator)
    Floor  -> emitZeroT
    Ceil   -> emitZeroT
    Round  -> emitZeroT
    LGamma -> notImplemented
    Erf    -> notImplemented
    Erfc   -> notImplemented
    FNeg   -> withT (neg x) (neg =<< tx)
    BNot   -> emitZeroT

linearizeBinOp :: Emits o => BinOp -> SAtom i -> SAtom i -> LinM i o SAtom SAtom
linearizeBinOp op x' y' = do
  WithTangent x tx <- linearizeAtom x'
  WithTangent y ty <- linearizeAtom y'
  let emitZeroT = withZeroT $ emitOp $ BinOp op x y
  case op of
    IAdd   -> emitZeroT
    ISub   -> emitZeroT
    IMul   -> emitZeroT
    IDiv   -> emitZeroT
    IRem   -> emitZeroT
    ICmp _ -> emitZeroT
    FAdd -> withT (add x y) (bindM2 add tx ty)
    FSub -> withT (sub x y) (bindM2 sub tx ty)
    FMul -> withT (mul x y)
                  (bindM2 add (bindM2 mul (referToPrimal x) ty)
                              (bindM2 mul tx (referToPrimal y)))
    FDiv -> withT (div' x y) do
      tx' <- bindM2 div' tx (referToPrimal y)
      ty' <- bindM2 div' (bindM2 mul (referToPrimal x) ty)
                      (bindM2 mul (referToPrimal y) (referToPrimal y))
      sub tx' ty'
    FPow -> withT (emitOp $ BinOp FPow x y) do
      px <- referToPrimal x
      py <- referToPrimal y
      c <- (1.0 `fLitLike` py) >>= (sub py) >>= fpow px
      tx' <- bindM2 mul tx (return py)
      ty' <- bindM2 mul (bindM2 mul (return px) ty) (flog px)
      mul c =<< add tx' ty'
    FCmp _ -> emitZeroT
    BAnd   -> emitZeroT
    BOr    -> emitZeroT
    BXor   -> emitZeroT
    BShL   -> emitZeroT
    BShR   -> emitZeroT

-- This has the same type as `sinkM` and falls back thereto, but recomputes
-- indexing a primal array in the tangent to avoid materializing intermediate
-- results thereof.  We should probably have a more cogent story for
-- rematerialization, but this suffices to remove embarrassing intermediates in
-- matrix multiplication.
referToPrimal :: (Builder SimpIR m, Emits l, DExt n l) => SAtom n -> m l (SAtom l)
referToPrimal x = do
  case x of
    Var v -> lookupEnv (sink v) >>= \case
      AtomNameBinding (LetBound (DeclBinding PlainLet _ (Atom atom))) ->
        referToPrimal atom
      AtomNameBinding (LetBound (DeclBinding PlainLet _ (TabApp tab is))) -> do
        tab' <- referToPrimal tab
        is' <- mapM referToPrimal is
        Var <$> emit (TabApp tab' is')
      _ -> sinkM x
    _ -> sinkM x

linearizePrimCon :: Emits o => Con SimpIR i -> LinM i o SAtom SAtom
linearizePrimCon con = case con of
  Lit _ -> emitZeroT
  ProdCon xs -> fmapLin (ProdVal . fromComposeE) $ seqLin (fmap linearizeAtom xs)
  SumCon  _ _ _ -> notImplemented
  SumAsProd tys tg elems -> do
    tys' <- forM tys \t -> renameM t
    tg' <- renameM tg
    -- There must be a way to do this with `seqLin` etc but it's too much for me
    elemsWithT <- traverse linearizeAtom elems
    let elemsP = fmap (\(WithTangent x _) -> x) elemsWithT
    return $ WithTangent (Con $ SumAsProd tys' tg' elemsP) do
      elemsT <- forM elemsWithT \(WithTangent _ t) -> t
      return $ Con $ SumAsProd (sinkList tys') (sink tg') elemsT
  DictHole _ _ -> error "impossible"  -- TODO: static constraint
  HeapVal -> emitZeroT
  where emitZeroT = withZeroT $ renameM $ Con con

linearizeHof :: Emits o => Hof SimpIR i -> LinM i o SAtom SAtom
linearizeHof hof = case hof of
  For d ixDict (UnaryLamExpr (ib:>ixTy) body) -> do
    ixDict' <- renameM ixDict
    ixTy'   <- renameM ixTy
    (lam', tanLam) <- withFreshBinder noHint ixTy' \ib' -> do
      (block', linLam) <- extendSubst (ib@>binderName ib') $ linearizeBlockDefunc body
      let ibAnn = ib' :> ixTy'
      return (UnaryLamExpr ibAnn block', Abs (UnaryNest ibAnn) linLam)
    (primals, residuals) <- emitExpr (Hof $ For d ixDict' lam') >>= unzipTab
    return $ WithTangent primals do
      buildFor noHint d (sink $ IxType ixTy' ixDict') \i' -> do
        residuals' <- tabApp (sink residuals) (Var i')
        applyLinLamAbsAbs (sink tanLam) [Var i'] residuals'
  RunReader r lam -> do
    WithTangent r' rLin <- linearizeAtom r
    (lam', recon) <- linearizeEffectFun Reader lam
    result <- liftM Var (emit $ Hof $ RunReader r' lam')
    (primalResult, residuals) <- fromPair result
    referentTy <- getReferentTypeRWSAction lam'
    return $ WithTangent primalResult do
      rLin' <- rLin
      tt <- tangentType $ sink referentTy
      tanEffLam <- buildEffLam Reader noHint tt \h ref ->
        extendTangentArgss [h, ref] do
          applyLinLamAbs (sink recon) (sink residuals)
      emitExpr $ Hof $ RunReader rLin' tanEffLam
  RunState Nothing sInit lam -> do
    WithTangent sInit' sLin <- linearizeAtom sInit
    (lam', recon) <- linearizeEffectFun State lam
    (result, sFinal) <- fromPair =<< liftM Var (emit $ Hof $ RunState Nothing sInit' lam')
    (primalResult, residuals) <- fromPair result
    referentTy <- getReferentTypeRWSAction lam'
    return $ WithTangent (PairVal primalResult sFinal) do
      sLin' <- sLin
      tt <- tangentType $ sink referentTy
      tanEffLam <- buildEffLam State noHint tt \h ref ->
        extendTangentArgss [h, ref] do
          applyLinLamAbs (sink recon) (sink residuals)
      emitExpr $ Hof $ RunState Nothing sLin' tanEffLam
  RunWriter Nothing bm lam -> do
    -- TODO: check it's actually the 0/+ monoid (or should we just build that in?)
    bm' <- renameM bm
    (lam', recon) <- linearizeEffectFun Writer lam
    (result, wFinal) <- fromPair =<< liftM Var (emit $ Hof $ RunWriter Nothing bm' lam')
    (primalResult, residuals) <- fromPair result
    referentTy <- getReferentTypeRWSAction lam'
    return $ WithTangent (PairVal primalResult wFinal) do
      bm'' <- sinkM bm'
      tt <- tangentType $ sink referentTy
      tanEffLam <- buildEffLam Writer noHint tt \h ref ->
        extendTangentArgss [h, ref] do
          applyLinLamAbs (sink recon) (sink residuals)
      emitExpr $ Hof $ RunWriter Nothing bm'' tanEffLam
  RunIO body -> do
    (body', linLam) <- linearizeBlockDefunc body
    (ans, residuals) <- fromPair =<< (liftM Var $ emit $ Hof $ RunIO body')
    return $ WithTangent ans $ applyLinLamAbs (sink linLam) (sink residuals)
  _ -> error $ "not implemented: " ++ pprint hof

linearizeEffectFun :: RWS -> SLam i -> PrimalM i o (SLam o, LinLamAbs o)
linearizeEffectFun rws (BinaryLamExpr hB refB body) = do
  eff <- getAllowedEffects
  withFreshBinder noHint (TC HeapType) \h -> do
    bTy <- extendSubst (hB@>binderName h) $ renameM $ binderType refB
    withFreshBinder noHint bTy \b -> do
      let ref = binderName b
      hVar <- sinkM $ binderName h
      let eff' = extendEffect (RWSEffect rws (Var hVar)) (sink eff)
      (body', linLam) <- withAllowedEffects eff' do
        extendActiveSubst hB hVar $ extendActiveSubst refB ref $
          -- TODO: maybe we should check whether we need to extend the active effects
          extendActiveEffs (RWSEffect rws (Var hVar)) do
            linearizeBlockDefunc body
      -- TODO: this assumes that references aren't returned. Our type system
      -- ensures that such references can never be *used* once the effect runner
      -- returns, but technically it's legal to return them.
      let linLam' = ignoreHoistFailure $ hoist (PairB h b) linLam
      return (BinaryLamExpr (h:>TC HeapType) (b:>bTy) body', linLam')
linearizeEffectFun _ _ = error "expect effect function to be a binary lambda"

withT :: PrimalM i o (e1 o)
      -> (forall o'. (Emits o', DExt o o') => TangentM o' (e2 o'))
      -> PrimalM i o (WithTangent o e1 e2)
withT p t = do
  p' <- p
  return $ WithTangent p' t

withZeroT :: PrimalM i o (Atom SimpIR o)
          -> PrimalM i o (WithTangent o SAtom SAtom)
withZeroT p = do
  p' <- p
  return $ WithTangent p' do
    pTy <- getType $ sink p'
    zeroAt =<< tangentType pTy

notImplemented :: HasCallStack => a
notImplemented = error "Not implemented"

-- === instances ===

instance GenericE ActivePrimals where
  type RepE ActivePrimals = PairE (ListE SAtomName) (EffectRow SimpIR)
  fromE (ActivePrimals vs effs) = ListE vs `PairE` effs
  {-# INLINE fromE #-}
  toE   (ListE vs `PairE` effs) = ActivePrimals vs effs
  {-# INLINE toE #-}

instance SinkableE   ActivePrimals
instance HoistableE  ActivePrimals
instance AlphaEqE    ActivePrimals
instance RenameE     ActivePrimals

instance GenericE TangentArgs where
  type RepE TangentArgs = ListE SAtomName
  fromE (TangentArgs vs) = ListE vs
  {-# INLINE fromE #-}
  toE   (ListE vs) = TangentArgs vs
  {-# INLINE toE #-}

instance SinkableE   TangentArgs
instance HoistableE  TangentArgs
instance AlphaEqE    TangentArgs
instance RenameE     TangentArgs
