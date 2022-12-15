-- Copyright 2022 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

module OccAnalysis (
  analyzeOccurrences
  ) where

import Control.Monad.State.Strict
import Data.Functor
import Data.List (foldl')
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Control.Monad.Reader.Class

import Core
import LabeledItems
import IRVariants
import Name
import MTL1
import Occurrence hiding (Var)
import Occurrence qualified as Occ
import Types.Core
import Types.Primitives
import QueryType

-- === External API ===

-- This annotates every `Let` binding in the given `Block` with an `OccInfo`
-- annotation holding a summary of how that binding is used.  It also eliminates
-- unused pure bindings as it goes, since it has all the needed information.

analyzeOccurrences :: (EnvReader m) => SBlock n -> m n (SBlock n)
analyzeOccurrences = liftOCCM . occ accessOnce
{-# SCC analyzeOccurrences #-}

-- === Overview ===

-- We analyze every binding in the program for occurrence information,
-- namely information on how much it is used.
--
-- If a (pure) binding is not used at all, we take the opportunity to
-- eliminate it.  Otherwise, we track both static and dynamic usage
-- information:
-- - If a binding is used statically at most once, then inlining it
--   does not increase code size
-- - If a binding is used dynamically at most once, then inlining it
--   does not increase runtime work
--
-- The static usage information is just an Int counting the number of
-- static uses.  The dynamic usage information is an
-- Occ.DynUseInfo, counting an upper bound on the number of
-- dynamic uses, and keeping track of how many dimensions of indexing
-- have to be apparent for inlining to be work-preserving.  (For
-- example, if the usage is `for i. xs.i`, in order to inline `xs`
-- safely, we need to have access to the `for` expression that
-- constructed it so as to cancel against the indexing expression.)

-- === Data Structure ===

-- Our primary operating structure is a map (potentially partial) from names to
-- their current Occ.AccessInfo information.

newtype FV (n::S) = FV { freeVars :: (NameMapE 'AtomNameC AccessInfo n) }

instance Monoid (FV n) where
  mempty = FV mempty
  mappend = (<>)

instance Semigroup (FV n) where
  (FV m1) <> (FV m2) = FV $ unionWithNameMapE plus m1 m2

deriving instance MaxPlus (FV n)

instance SinkableE FV where
  sinkingProofE _ _ = todoSinkableProof
instance HoistableState FV where
  -- By this point we need to make sure that none of the AccessInfo in the map
  -- refer to the binder being hoisted above.
  hoistState _ b (FV ns) = FV $ case hoistNameMapE b ns of
    HoistFailure vs -> error $ "Could not hoist: " ++ show vs ++ " escaped"
    HoistSuccess ns' -> ns'
  {-# INLINE hoistState #-}

-- Close every AccessInfo in the given FV by abstracting over the given binder
-- with `Occ.ForEach`, i.e., because it's the binder of a `for`.
-- We internally sink back under the binder because we are not (yet) removing
-- the entry for the binder itself, and the type of NameMapE cannot represent a
-- map from names in `l` to E-kinded things with names in `n` (though maybe it
-- should be changed?)
abstractFor :: DExt n l => Binder SimpIR n l -> FV l -> FV l
abstractFor (b:>_) (FV fvs) = FV $ mapNameMapE update fvs where
  update (AccessInfo s dyn) = sink $ AccessInfo s $ ForEach b dyn

-- Change all the AccessInfos to assume their objects are dynamically used many
-- times, as in the body of a `while`.
useManyTimes :: FV n -> FV n
useManyTimes (FV fvs) = FV $ mapNameMapE update fvs where
  update (AccessInfo s d) = AccessInfo s $ accessMuch d

-- Change all the AccessInfos to assume their objects are _statically_ used many
-- times, as for expressions that will be inlined unpredictably.
-- TODO(precision): If this is for a `view`, we could use the occurrence
-- information of the view itself to predict how much of an amplification
-- inlining it would cause.
useManyTimesStatic :: FV n -> FV n
useManyTimesStatic (FV fvs) = FV $ mapNameMapE update fvs where
  -- TODO(code cleanliness): Do we want to change the static counter to a Count
  -- so the Unbounded constructor is available here?
  update (AccessInfo _ d) = AccessInfo maxBound d

-- === Monad ===

-- We carry the above FV data structure, which is accumulated bottom up; and
-- also an environment accumulated top down that gives, for each name we have
-- encountered, an `IxExpr` summarizing what indexing by that name might mean,
-- should such indexing occur in that name's scope.
--
-- These `IxExpr`s are in terms of
-- - Binders already in scope when the analysis begins (e.g., the top-level
--   environment), and
-- - Binders introduced by `for`

type OCCM = ReaderT1 (NameMapE 'AtomNameC IxExpr) (StateT1 FV EnvReaderM)

liftOCCM :: (EnvReader m) => OCCM n a -> m n a
liftOCCM action = liftEnvReaderM $ fst
  <$> runStateT1 (runReaderT1 mempty action) mempty
{-# INLINE liftOCCM #-}

getAccessInfo :: SAtomName n -> OCCM n (AccessInfo n)
getAccessInfo name = fromMaybe zero <$> gets (lookupNameMapE name . freeVars)
{-# INLINE getAccessInfo #-}

countFreeVarsAsOccurrences :: (HoistableE e) => e n -> OCCM n ()
countFreeVarsAsOccurrences obj =
  forM_ (freeAtomVarsList obj) \name -> do
    modify (<> FV (singletonNameMapE name $ AccessInfo One accessOnce))

countFreeVarsAsOccurrencesB :: (HoistableB b) => b n l -> OCCM n ()
countFreeVarsAsOccurrencesB obj =
  forM_ (freeAtomVarsList $ Abs obj UnitE) \name -> do
    modify (<> FV (singletonNameMapE name $ AccessInfo One accessOnce))

-- Run the given action with its own FV state, and return the FVs it
-- accumulates for post-processing.
isolated :: OCCM n a -> OCCM n (a, FV n)
isolated action = do
  r <- ask
  lift11 $ lift11 $ runStateT1 (runReaderT1 r action) mempty

-- Extend the IxExpr environment
extend :: (BindsOneName b 'AtomNameC)
  => b any n -> IxExpr n -> OCCM n a -> OCCM n a
extend b ix = local (<> singletonNameMapE (binderName b) ix)

-- Look up the `IxExpr` for a given name.  If the name doesn't occur in the map,
-- we return a `Occ.Var` of the name itself, thus claiming that the name is its
-- own summary.  This is what we want for `for` binders and top-level names.
ixExpr :: SAtomName n -> OCCM n (IxExpr n)
ixExpr name = do
  ixExprs <- ask
  case lookupNameMapE name ixExprs of
    Just ans -> return $ ans
    Nothing -> return $ Occ.Var name

-- `TabLamExpr` and `IxDicts` are meant to be inlined themselves, so we
-- have to assume that their occurrences may be replicated many times,
-- including statically.
inlinedLater :: (HoistableE e) => e n -> OCCM n (e n)
inlinedLater obj = do
  (_, fvs) <- isolated $ countFreeVarsAsOccurrences obj
  modify (<> useManyTimesStatic (useManyTimes fvs))
  return obj

-- === Computing IxExpr summaries ===

summaryExpr :: SExpr n -> OCCM n (IxExpr n)
summaryExpr = \case
  Atom atom -> summary atom
  expr -> unknown expr

summary :: SAtom n -> OCCM n (IxExpr n)
summary atom = case atom of
  Var name -> ixExpr name
  Con c -> constructor c
  ACase _ _ _ -> error "Unexpected ACase outside of Simplify"
  _ -> unknown atom
  where
    invalid tag = error $ "Unexpected indexing by " ++ tag
    constructor = \case
      -- TODO Represent the actual literal value?
      Lit _ -> return $ Deterministic []
      ProdCon elts -> Product <$> mapM summary elts
      SumCon _ tag payload -> Inject tag <$> summary payload
      SumAsProd _ (TagRepVal tag) payloads ->
        Inject (fromIntegral tag) <$> (summary $ payloads !! (fromIntegral tag))
      SumAsProd _ _ _ -> unknown atom
      LabelCon _ -> invalid "LabelCon"
      Newtype _ e -> summary e
      ExplicitDict _ _ -> invalid "ExplicitDict"
      DictHole _ _ -> invalid "DictHole"

unknown :: HoistableE e => e n -> OCCM n (IxExpr n)
unknown _ = return IxAll
  -- TODO(precision) It should be possible to return `Deterministic <free
  -- variables>` in most cases.  That's only unsound if
  -- - Any of the ixExpr of the free variables are themselves IxAll (which is
  --   easy to detect); or
  -- - The object has a funny effect like `IO`.  (Note that we wouldn't have to
  --   detect reader, writer, and state effects specially, because the summary
  --   of the reference should already have any necessary `IxAll` in it.)

-- === The actual occurrence analysis ===

class HasOCC (e::E) where
  occ :: Access n -> e n -> OCCM n (e n)
  default occ :: (GenericE e, HasOCC (RepE e)) => Access n -> e n -> OCCM n (e n)
  occ a e = confuseGHC >>= \_ -> toE <$> occ a (fromE e)

instance HasOCC (Name AtomNameC) where
  occ a n = modify (<> FV (singletonNameMapE n $ AccessInfo One a)) $> n
  {-# INLINE occ #-}
instance HasOCC (Name HandlerNameC ) where occ _ n = return n
instance HasOCC (Name DataDefNameC ) where occ _ n = return n
instance HasOCC (Name EffectNameC  ) where occ _ n = return n
instance HasOCC (Name InstanceNameC) where occ _ n = return n
instance HasOCC (Name ClassNameC   ) where occ _ n = return n
instance HasOCC (Name SpecializedDictNameC) where occ _ n = return n

instance HasOCC SBlock where
  occ a (Block ann decls ans) = case (ann, decls) of
    (NoBlockAnn      , Empty) -> Block NoBlockAnn Empty <$> occ a ans
    (NoBlockAnn      , _    ) -> error "should be unreachable"
    (BlockAnn ty effs, _    ) -> do
      Abs decls' ans' <- occNest a decls ans
      ty' <- occTy ty
      countFreeVarsAsOccurrences effs
      return $ Block (BlockAnn ty' effs) decls' ans'

-- TODO What, actually, is the right thing to do for type annotations?  Do we
-- want a rule like "we never inline into type annotations", or such?  For
-- now, traversing with the main analysis seems safe.
occTy :: SAtom n -> OCCM n (SAtom n)
occTy ty = occ accessOnce ty

-- TODO(optimization) Could reuse the free variable caching from dce here too.

data ElimResult (n::S) where
  ElimSuccess :: Abs (Nest SDecl) SAtom n -> ElimResult n
  ElimFailure :: SDecl n l -> UsageInfo -> Abs (Nest SDecl) SAtom l -> ElimResult n

occNest :: Access n -> Nest SDecl n l -> SAtom l
        -> OCCM n (Abs (Nest SDecl) SAtom n)
occNest a decls ans = case decls of
  Empty -> Abs Empty <$> occ a ans
  Nest d@(Let _ binding) ds -> do
    isPureDecl <- isPure binding
    dceAttempt <- refreshAbs (Abs d (Abs ds ans))
      \d'@(Let b' (DeclBinding _ _ expr')) (Abs ds' ans') -> do
        exprIx <- summaryExpr $ sink expr'
        extend b' exprIx do
          below <- occNest (sink a) ds' ans'
          checkAllFreeVariablesMentioned below
          accessInfo <- getAccessInfo $ binderName d'
          let usage = usageInfo accessInfo
          let dceAttempt = case isPureDecl of
               False -> ElimFailure d' usage below
               True  ->
                 -- Or hoistUsingCachedFVs in the monad, if we decide to do
                 -- that optimization
                 case hoist d' below of
                   HoistSuccess below' -> ElimSuccess below'
                   HoistFailure _ -> ElimFailure d' usage below
          return dceAttempt
    case dceAttempt of
      ElimSuccess below' -> return below'
      ElimFailure (Let b' binding') usage (Abs ds'' ans'') -> do
        -- Using accessOnce here, instead of the computed Access for
        -- the decl's binder.  This means that variable bindings cut
        -- occurrence analysis, and each binding is considered for
        -- inlining separately.
        DeclBinding _ ty expr <- occ accessOnce binding'
        -- We save effects information here because the inliner will want to
        -- query the effects of an expression before it is substituted, and the
        -- type querying subsystem is not set up to do that.
        effs <- getEffects expr
        let ann = if effs == Pure
              then OccInfoPure usage
              else OccInfoImpure usage
        let binding'' = DeclBinding ann ty expr
        return $ Abs (Nest (Let b' binding'') ds'') ans''

checkAllFreeVariablesMentioned :: HoistableE e => e n -> OCCM n ()
checkAllFreeVariablesMentioned e = do
#ifdef DEX_DEBUG
  FV fvs <- get
  forM_ (nameSetToList (freeVarsE e)) \name ->
    case lookupNameMapE name fvs of
      Just _ -> return ()
      Nothing -> error $ "Free variable map missing free variable " ++ show name
#else
  void $ return e  -- Refer to `e` in this branch to avoid a GHC warning
  return ()
{-# INLINE checkAllFreeVariablesMentioned #-}
#endif

instance HasOCC (DeclBinding SimpIR) where
  occ a (DeclBinding ann ty expr) = do
    expr' <- occ a expr
    ty' <- occTy ty
    return $ DeclBinding ann ty' expr'

instance HasOCC SExpr where
  occ a expr = case expr of
    (TabApp array (NE.toList -> ixs)) -> do
      (a', ixs') <- go a ixs
      array' <- occ a' array
      return $ TabApp array' $ NE.fromList ixs'
    (Case scrut alts ty effs) -> do
      scrut' <- occ accessOnce scrut
      scrutIx <- summary scrut
      (alts', innerFVs) <- unzip <$> mapM (isolated . occAlt a scrutIx) alts
      modify (<> foldl' Occ.max zero innerFVs)
      ty' <- occTy ty
      countFreeVarsAsOccurrences effs
      return $ Case scrut' alts' ty' effs
    _ -> generic
    where
      generic = toE <$> (occ a $ fromE expr)
      go acc [] = return (acc, [])
      go acc (ix:ixs) = do
        (acc', ixs') <- go acc ixs
        (summ, ix') <- occurrenceAndSummary ix
        return (location summ acc', ix':ixs')

instance HasOCC (ComposeE PrimOp SAtom) where
  -- I'm pretty sure the others are all strict, and not usefully analyzable
  -- for what they do to the incoming access pattern.
  occ _ (ComposeE op) = ComposeE <$> traverse (occ accessOnce) op
  {-# INLINE occ #-}

-- Arguments: Usage of the return value, summary of the scrutinee, the
-- alternative itself.
occAlt :: Access n -> IxExpr n -> Alt SimpIR n -> OCCM n (Alt SimpIR n)
occAlt acc scrut alt = do
  (Abs (b':>ty) body') <- refreshAbs alt \b@(nb:>_) body -> do
    -- We use `unknown` here as a conservative approximation of the case binder
    -- being the scrutinee with the top constructor removed.  If we statically
    -- knew what that constructor was we could remove it, but I guess that
    -- case-of-known-constructor optimization would have already eliminated this
    -- case statement in that event.
    scrutIx <- unknown $ sink scrut
    extend nb scrutIx do
      body' <- occ (sink acc) body
      return $ Abs b body'
  ty' <- occTy ty
  return $ Abs (b':>ty') body'

occurrenceAndSummary :: SAtom n -> OCCM n (IxExpr n, SAtom n)
occurrenceAndSummary atom = do
  atom' <- occ accessOnce atom
  ix <- summary atom'
  return (ix, atom')

instance HasOCC (Hof SimpIR) where
  occ a hof = case hof of
    For ann ixDict (UnaryLamExpr b body) -> do
      ixDict' <- inlinedLater ixDict
      occWithBinder (Abs b body) \b' body' -> do
        extend b' (Occ.Var $ binderName b') do
          (body'', bodyFV) <- isolated (occ accessOnce body')
          modify (<> abstractFor b' bodyFV)
          return $ For ann ixDict' (UnaryLamExpr b' body'')
    For _ _ _ -> error "For body should be a unary lambda expression"
    While body -> While <$> do
      (body', bodyFV) <- isolated (occ accessOnce body)
      modify (<> useManyTimes bodyFV)
      return body'
    RunReader ini bd -> do
      ini' <- occ accessOnce ini
      iniIx <- summary ini
      bd' <- oneShot a [Deterministic [], iniIx]bd
      return $ RunReader ini' bd'
    RunWriter Nothing (BaseMonoid empty combine) bd -> do
      -- We will process the combining function when we meet it in MExtend ops
      -- (but we won't attempt to eliminate dead code in it).
      empty' <- occ accessOnce empty
      -- There is no way to read from the reference in a Writer, so the only way
      -- an indexing expression can depend on it is by referring to the
      -- reference itself.  One way to so refer that is opaque to occurrence
      -- analysis would be to pass the reference to a standalone function which
      -- returns an index (presumably without actually reading any information
      -- from said reference).
      --
      -- To cover this case, we write `Deterministic []` here.  This is correct,
      -- because RunWriter creates the reference without reading any external
      -- names.  In particular, in the event of `RunWriter` in a loop, the
      -- different references across loop iterations are not distinguishable.
      -- The same argument holds for the heap parameter.
      bd' <- oneShot a [Deterministic [], Deterministic []] bd
      return $ RunWriter Nothing (BaseMonoid empty' combine) bd'
    RunWriter (Just _) _ _ ->
      error "Expecting to do occurrence analysis before destination passing."
    RunState Nothing ini bd -> do
      ini' <- occ accessOnce ini
      -- If we wanted to be more precise, the summary for the reference should
      -- be something about the stuff that might flow into the `put` operations
      -- affecting that reference.  Using `IxAll` is a conservative
      -- approximation (in downstream analysis it means "assume I touch every
      -- value").
      bd' <- oneShot a [Deterministic [], IxAll]bd
      return $ RunState Nothing ini' bd'
    RunState (Just _) _ _ ->
      error "Expecting to do occurrence analysis before destination passing."
    RunIO bd -> RunIO <$> occ a bd
    RunInit _ ->
      -- Though this is probably not too hard to implement.  Presumably
      -- the lambda is one-shot.
      error "Expecting to do occurrence analysis before lowering."

oneShot :: Access n -> [IxExpr n] -> LamExpr SimpIR n -> OCCM n (LamExpr SimpIR n)
oneShot acc [] (LamExpr Empty body) = LamExpr Empty <$> occ acc body
oneShot acc (ix:ixs) (LamExpr (Nest b bs) body) = do
  occWithBinder (Abs b (LamExpr bs body)) \b' restLam ->
    extend b' (sink ix) do
      LamExpr bs' body' <- oneShot (sink acc) (map sink ixs) restLam
      return $ LamExpr (Nest b' bs') body'
oneShot _ _ _ = error "zip error"

-- Going under a lambda binder.
occWithBinder
  :: (SubstE Name e)
  => Abs (Binder SimpIR) e n
  -> (forall l. DExt n l => Binder SimpIR n l -> e l -> OCCM l a)
  -> OCCM n a
occWithBinder (Abs (b:>ty) body) cont = do
  ty' <- occTy ty
  refreshAbs (Abs (b:>ty') body) cont
{-# INLINE occWithBinder #-}

instance HasOCC SAtom where
  occ a atom = case atom of
    ACase _ _ _ -> error "Unexpected ACase outside of Simplify"
    _ -> generic
    where
      generic = toE <$> (occ a $ fromE atom)

-- We shouldn't need this instance, because Imp names can't appear in SimpIR,
-- but we need to add some tricks to make GHC realize that.
instance HasOCC (Name ImpNameC) where occ _ = error "Unexpected ImpName"

instance HasOCC (Name PtrNameC) where occ _ x = return x

instance HasOCC (TabLamExpr SimpIR) where
  occ _ view = inlinedLater view
  {-# INLINE occ #-}

instance HasOCC (RefOp SimpIR) where
  occ _ = \case
    MExtend (BaseMonoid empty combine) val -> do
      val' <- occ accessOnce val
      valIx <- summary val'
      -- TODO(precision) The empty value of the monoid is presumably dead here,
      -- but we pretend like it's not to make sure that occurrence analysis
      -- results mention every free variable in the traversed expression.  This
      -- may lead to missing an opportunity to inline something into the empty
      -- value of the given monoid, since references thereto will be overcounted.
      empty' <- occ accessOnce empty
      -- Treat the combining function as inlined here and called once
      combine' <- oneShot accessOnce [Deterministic [], valIx] combine
      return $ MExtend (BaseMonoid empty' combine') val'
    -- I'm pretty sure the others are all strict, and not usefully analyzable
    -- for what they do to the incoming access pattern.
    MPut x -> MPut <$> occ accessOnce x
    MGet -> return MGet
    MAsk -> return MAsk
    IndexRef i -> IndexRef <$> occ accessOnce i
    ProjRef  i -> return $ ProjRef i
  {-# INLINE occ #-}

-- === The generic instances ===

instance HasOCC e => HasOCC (ComposeE (PrimCon r) e) where
  occ _ (ComposeE con) = ComposeE <$> traverse (occ accessOnce) con
  {-# INLINE occ #-}

instance HasOCC e => HasOCC (ComposeE (PrimTC r) e) where
  occ _ (ComposeE tc) = ComposeE <$> traverse (occ accessOnce) tc
  {-# INLINE occ #-}

instance HasOCC e => HasOCC (ComposeE LabeledItems e) where
  occ _ (ComposeE items) = ComposeE <$> traverse (occ accessOnce) items
  {-# INLINE occ #-}

instance (HasOCC e1, HasOCC e2) => HasOCC (ExtLabeledItemsE e1 e2)
instance HasOCC (LamExpr SimpIR) where
  occ _ _ = error "Impossible"
  {-# INLINE occ #-}
instance HasOCC (PiType SimpIR)
instance HasOCC (TabPiType SimpIR)
instance HasOCC (DepPairType SimpIR)
instance HasOCC EffectRow
instance HasOCC Effect
instance HasOCC (DictExpr SimpIR)
instance HasOCC (DictType SimpIR)
instance HasOCC (FieldRowElems SimpIR)
instance HasOCC (FieldRowElem SimpIR)
instance HasOCC (DataDefParams SimpIR)
instance HasOCC (DAMOp SimpIR)

-- === The instances for RepE types ===

-- These are only correct for strict expressions whose effects we do
-- not wish to analyze.  That is, the assumption is that they fully
-- use every variable that occurs in them.

instance (HasOCC e1, HasOCC e2) => HasOCC (PairE e1 e2) where
  occ _ (PairE l r) = PairE <$> occ accessOnce l <*> occ accessOnce r
  {-# INLINE occ #-}
instance (HasOCC e1, HasOCC e2) => HasOCC (EitherE e1 e2) where
  occ a = \case
    LeftE  l -> LeftE  <$> occ a l
    RightE r -> RightE <$> occ a r
  {-# INLINE occ #-}
instance ( HasOCC e0, HasOCC e1, HasOCC e2, HasOCC e3
         , HasOCC e4, HasOCC e5, HasOCC e6, HasOCC e7
         ) => HasOCC (EitherE8 e0 e1 e2 e3 e4 e5 e6 e7) where
  occ a = \case
    Case0 x0 -> Case0 <$> occ a x0
    Case1 x1 -> Case1 <$> occ a x1
    Case2 x2 -> Case2 <$> occ a x2
    Case3 x3 -> Case3 <$> occ a x3
    Case4 x4 -> Case4 <$> occ a x4
    Case5 x5 -> Case5 <$> occ a x5
    Case6 x6 -> Case6 <$> occ a x6
    Case7 x7 -> Case7 <$> occ a x7
  {-# INLINE occ #-}
instance (BindsEnv b, SubstB Name b, HoistableB b, SubstE Name e, HasOCC e)
  => HasOCC (Abs b e) where
  occ access a = do
    -- The way this and hoistState are written, the pass will crash if any of
    -- the AccessInfos reference this binder.  We should avoid triggering this
    -- generic instance in any situation where that can happen.
    a'@(Abs b' _) <- refreshAbs a \b e -> Abs b <$> occ (sink access) e
    countFreeVarsAsOccurrencesB b'
    return a'
  {-# INLINE occ #-}
instance HasOCC (LiftE a) where
  occ _ x = return x
  {-# INLINE occ #-}
instance HasOCC VoidE where
  occ _ _ = error "impossible"
  {-# INLINE occ #-}
instance HasOCC UnitE where
  occ _ UnitE = return UnitE
  {-# INLINE occ #-}
instance HasOCC e => HasOCC (ListE e) where
  occ _ (ListE xs) = ListE <$> traverse (occ accessOnce) xs
  {-# INLINE occ #-}

instance HasOCC e => HasOCC (WhenE True e) where
  occ a (WhenE e) = WhenE <$> occ a e
instance HasOCC (WhenE False e) where
  occ _ _ = undefined

-- See Note [Confuse GHC] from Simplify.hs
confuseGHC :: EnvReader m => m n (DistinctEvidence n)
confuseGHC = getDistinct
{-# INLINE confuseGHC #-}
