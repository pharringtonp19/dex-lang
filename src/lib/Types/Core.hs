-- Copyright 2022 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE ConstraintKinds #-}

-- Core data types for CoreIR and its variations.

module Types.Core (module Types.Core, SymbolicZeros (..)) where

import Control.Applicative
import Control.Monad.Writer.Strict (Writer, execWriter, tell)
import Data.Word
import Data.Functor
import Data.Foldable (toList)
import Data.Hashable
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text.Prettyprint.Doc  hiding (nest)
import qualified Data.Map.Strict       as M
import qualified Data.Set              as S

import GHC.Generics (Generic (..))
import Data.Store (Store (..))
import Foreign.Ptr

import Name
import Err
import LabeledItems
import Util (FileHash, onFst, SnocList (..), toSnocList, Tree (..))
import IRVariants

import Types.Primitives
import Types.Source
import Types.Imp

-- === core IR ===

data Atom (r::IR) (n::S) where
 Var        :: AtomName r n    -> Atom r n
 TabPi      :: TabPiType r n   -> Atom r n
 Con        :: Con r n         -> Atom r n
 TC         :: TC  r n         -> Atom r n
 PtrVar     :: PtrName n       -> Atom r n
 ProjectElt :: Projection -> Atom r n                   -> Atom r n
 DepPair    :: Atom r n -> Atom r n -> DepPairType r n  -> Atom r n
 DepPairTy  :: DepPairType r n                          -> Atom r n
 -- === CoreIR only ===
 -- The binder in the `EffAbs n` is meant to be parallel to the binder in
 -- the `LamExpr`, of which there must be only one (for now).
 Lam          :: LamExpr CoreIR n -> Arrow -> EffAbs n -> Atom CoreIR n
 Pi           :: PiType  n                     -> Atom CoreIR n
 Eff          :: EffectRow CoreIR n            -> Atom CoreIR n
 DictCon      :: DictExpr n                    -> Atom CoreIR n
 DictTy       :: DictType n                    -> Atom CoreIR n
 NewtypeCon   :: NewtypeCon n -> Atom CoreIR n -> Atom CoreIR n
 NewtypeTyCon :: NewtypeTyCon n                -> Atom CoreIR n
 -- === Shims between IRs ===
 SimpInCore   :: SimpInCore n    -> Atom CoreIR n
 RepValAtom   :: RepVal SimpIR n -> Atom SimpIR n

type TabLamExpr = Abs (IxBinder SimpIR) (Abs (Nest SDecl) CAtom)
data SimpInCore (n::S) =
   LiftSimp (Maybe (CType n)) (SAtom n)
 | LiftSimpFun (PiType n) (LamExpr SimpIR n)
 | TabLam (TabPiType CoreIR n) (TabLamExpr n)
 | ACase (SAtom n) [Abs SBinder CAtom n] (CType n)
 deriving (Show, Generic)

deriving instance IRRep r => Show (Atom r n)
deriving via WrapE (Atom r) n instance IRRep r => Generic (Atom r n)

data Expr r n where
 TopApp :: TopFunName n -> [SAtom n]         -> Expr SimpIR n
 TabApp :: Atom r n -> NonEmpty (Atom r n)   -> Expr r n
 Case   :: Atom r n -> [Alt r n] -> Type r n -> EffectRow r n -> Expr r n
 Atom   :: Atom r n                          -> Expr r n
 Hof    :: Hof r n                           -> Expr r n
 TabCon :: Type r n -> [Atom r n]            -> Expr r n
 RefOp  :: Atom r n -> RefOp r n             -> Expr r n
 PrimOp :: PrimOp (Atom r n)                 -> Expr r n
 App             :: Atom CoreIR n -> NonEmpty (Atom CoreIR n)-> Expr CoreIR n
 UserEffectOp    :: UserEffectOp n                           -> Expr CoreIR n
 ProjMethod      :: Atom CoreIR n -> Int                     -> Expr CoreIR n
 RecordVariantOp :: RecordVariantOp (Atom CoreIR n)          -> Expr CoreIR n
 DAMOp           :: DAMOp SimpIR n           -> Expr SimpIR n

deriving instance IRRep r => Show (Expr r n)
deriving via WrapE (Expr r) n instance IRRep r => Generic (Expr r n)

data BaseMonoid r n =
  BaseMonoid { baseEmpty   :: Atom r n
             , baseCombine :: LamExpr r n }
  deriving (Show, Generic)

type EffAbs = Abs (Binder CoreIR) (EffectRow CoreIR)

data DeclBinding r n = DeclBinding LetAnn (Type r n) (Expr r n)
     deriving (Show, Generic)
data Decl (r::IR) (n::S) (l::S) = Let (AtomNameBinder r n l) (DeclBinding r n)
     deriving (Show, Generic)
type Decls r = Nest (Decl r)

-- TODO: make this a newtype with an unsafe constructor The idea is that the `r`
-- parameter will play a role a bit like the `c` parameter in names: if you have
-- an `AtomName r n` and you look up its definition in the `Env`, you're sure to
-- get an `AtomBinding r n`.
type AtomName       (r::IR) = Name (AtomNameC r)
type AtomNameBinder (r::IR) = NameBinder (AtomNameC r)

type ClassName    = Name ClassNameC
type DataDefName  = Name DataDefNameC
type EffectName   = Name EffectNameC
type EffectOpName = Name EffectOpNameC
type HandlerName  = Name HandlerNameC
type InstanceName = Name InstanceNameC
type MethodName   = Name MethodNameC
type ModuleName   = Name ModuleNameC
type PtrName      = Name PtrNameC
type SpecDictName = Name SpecializedDictNameC
type TopFunName   = Name TopFunNameC
type FunObjCodeName = Name FunObjCodeNameC

type AtomBinderP (r::IR) = BinderP (AtomNameC r)
type Binder r = AtomBinderP r (Type r) :: B
type Alt r = Abs (Binder r) (Block r) :: E

-- The additional invariant enforced by this newtype is that the list should
-- never contain empty StaticFields members, nor StaticFields in two consecutive
-- positions.
newtype FieldRowElems (n::S) = UnsafeFieldRowElems { fromFieldRowElems :: [FieldRowElem n] }
        deriving (Show, Generic)

data FieldRowElem (n::S)
  = StaticFields (LabeledItems (Type CoreIR n))
  | DynField     (AtomName CoreIR n) (Type CoreIR n)
  | DynFields    (AtomName CoreIR n)
  deriving (Show, Generic)

data DataDef n where
  -- The `SourceName` is just for pretty-printing. The actual alpha-renamable
  -- binder name is in UExpr and Env
  DataDef :: SourceName -> Nest RolePiBinder n l -> [DataConDef l] -> DataDef n

data DataConDef n =
  -- Name for pretty printing, constructor elements, representation type,
  -- list of projection indices that recovers elements from the representation.
  DataConDef SourceName (CType n) [[Projection]]
  deriving (Show, Generic)

data ParamRole = TypeParam | DictParam | DataParam deriving (Show, Generic, Eq)

newtype DataDefParams n = DataDefParams [(Arrow, Atom CoreIR n)]
  deriving (Show, Generic)

-- The Type is the type of the result expression (and thus the type of the
-- block). It's given by querying the result expression's type, and checking
-- that it doesn't have any free names bound by the decls in the block. We store
-- it separately as an optimization, to avoid having to traverse the block.
-- If the decls are empty we can skip the type annotation, because then we can
-- cheaply query the result, and, more importantly, there's no risk of having a
-- type that mentions local variables.
data Block (r::IR) (n::S) where
  Block :: BlockAnn r n l -> Nest (Decl r) n l -> Atom r l -> Block r n

data BlockAnn r n l where
  BlockAnn :: Type r n -> EffectRow r n -> BlockAnn r n l
  NoBlockAnn :: BlockAnn r n n

data LamBinding (n::S) = LamBinding Arrow (CType n)
  deriving (Show, Generic)

data LamExpr (r::IR) (n::S) where
  LamExpr :: Nest (Binder r) n l -> Block r l -> LamExpr r n

data DestBlock (r::IR) (n::S) where
  -- The binder is for the destination that holds the result of the Block.
  -- The Block itself should not return anything -- it communicates results
  -- entirely through the destination.
  DestBlock :: forall r n l. Binder r n l -> Block r l -> DestBlock r n

data DestLamExpr (r::IR) (n::S) where
  DestLamExpr :: Nest (Binder r) n l -> DestBlock r l -> DestLamExpr r n

data IxDict r n where
  IxDictAtom        :: Atom CoreIR n         -> IxDict CoreIR n
  -- TODO: make these two only available in SimpIR (currently we can't do that
  -- because we need CoreIR to be a superset of SimpIR)
  -- IxDictRawFin is used post-simplification. It behaves like `Fin`, but
  -- it's parameterized by a newtyped-stripped `IxRepVal` instead of `Nat`, and
  -- it describes indices of type `IxRepVal`.
  IxDictRawFin      :: Atom r n                                 -> IxDict r n
  IxDictSpecialized :: Type r n -> SpecDictName n -> [Atom r n] -> IxDict r n

deriving instance IRRep r => Show (IxDict r n)
deriving via WrapE (IxDict r) n instance IRRep r => Generic (IxDict r n)

data IxMethod = Size | Ordinal | UnsafeFromOrdinal
     deriving (Show, Generic, Enum, Bounded, Eq)

data IxType (r::IR) (n::S) =
  IxType { ixTypeType :: Type r n
         , ixTypeDict :: IxDict r n }
  deriving (Show, Generic)

type IxBinder r = BinderP (AtomNameC r) (IxType r)

data TabPiType (r::IR) (n::S) where
  TabPiType :: IxBinder r n l -> Type r l -> TabPiType r n

data NaryPiType (r::IR) (n::S) where
  NaryPiType :: Nest (Binder r) n l -> EffectRow r l -> Type r l -> NaryPiType r n

data PiBinding (n::S) = PiBinding Arrow (Type CoreIR n)
  deriving (Show, Generic)

data PiBinder (n::S) (l::S) =
  PiBinder (AtomNameBinder CoreIR n l) (CType n) Arrow
  deriving (Show, Generic)

data PiType (n::S) where
  PiType :: PiBinder n l -> EffectRow CoreIR l -> Type CoreIR l -> PiType n

data DepPairType (r::IR) (n::S) where
  DepPairType :: Binder r n l -> Type r l -> DepPairType r n

data Projection =
   UnwrapNewtype -- TODO: add `HasCore r` constraint
 | ProjectProduct Int
     deriving (Show, Eq, Generic)

type Val  = Atom
type Type = Atom
type Kind = Type
type Dict = Atom CoreIR

type TC  r n = PrimTC  r (Atom r n)
type Con r n = PrimCon r (Atom r n)

-- A nest where the annotation of a binder cannot depend on the binders
-- introduced before it. You can think of it as introducing a bunch of
-- names into the scope in parallel, but since safer names only reasons
-- about sequential scope extensions, we encode it differently.
data NonDepNest r ann n l = NonDepNest (Nest (AtomNameBinder r) n l) [ann n]
                            deriving (Generic)

-- === Various ops ===

data Hof r n where
 For       :: ForAnn -> IxDict r n -> LamExpr r n -> Hof r n
 While     :: Block r n -> Hof r n
 RunReader :: Atom r n -> LamExpr r n -> Hof r n
 RunWriter :: Maybe (Atom r n) -> BaseMonoid r n -> LamExpr r n -> Hof r n
 RunState  :: Maybe (Atom r n) -> Atom r n -> LamExpr r n -> Hof r n  -- dest, initial value, body lambda
 RunIO     :: Block r n -> Hof r n
 RunInit   :: Block r n -> Hof r n
 CatchException :: Block   CoreIR n -> Hof CoreIR n
 Linearize      :: LamExpr CoreIR n -> Atom CoreIR n -> Hof CoreIR n
 Transpose      :: LamExpr CoreIR n -> Atom CoreIR n -> Hof CoreIR n

deriving instance IRRep r => Show (Hof r n)
deriving via WrapE (Hof r) n instance IRRep r => Generic (Hof r n)


-- Ops for "Dex Abstract Machine"
data DAMOp r n =
   Seq Direction (IxDict r n) (Atom r n) (LamExpr r n)   -- ix dict, carry dests, body lambda
 | RememberDest (Atom r n) (LamExpr r n)
 | AllocDest (Atom r n)        -- type
 | Place (Atom r n) (Atom r n) -- reference, value
 | Freeze (Atom r n)           -- reference
   deriving (Show, Generic)

data RefOp r n =
   MAsk
 | MExtend (BaseMonoid r n) (Atom r n)
 | MGet
 | MPut (Atom r n)
 | IndexRef (Atom r n)
 | ProjRef Int
  deriving (Show, Generic)

data UserEffectOp n =
   Handle (HandlerName n) [CAtom n] (CBlock n)
 | Resume (CAtom n) (CAtom n) -- Resume from effect handler (type, arg)
 | Perform (CAtom n) Int      -- Call an effect operation (effect name) (op #)
   deriving (Show, Generic)

-- === IR variants ===

type CAtom  = Atom CoreIR
type CType  = Type CoreIR
type CBinder = Binder CoreIR
type CExpr  = Expr CoreIR
type CBlock = Block CoreIR
type CDecl  = Decl  CoreIR
type CDecls = Decls CoreIR
type CAtomName  = AtomName CoreIR

type SAtom  = Atom SimpIR
type SType  = Type SimpIR
type SExpr  = Expr SimpIR
type SBlock = Block SimpIR
type SDecl  = Decl  SimpIR
type SDecls = Decls SimpIR
type SAtomName  = AtomName SimpIR
type SBinder = Binder SimpIR
type SRepVal = RepVal SimpIR
type SLam    = LamExpr SimpIR

-- === newtypes ===

-- Describes how to lift the "shallow" representation type to the newtype.
data NewtypeCon (n::S) =
   RecordCon  (LabeledItems ())
 | VariantCon (LabeledItems ())
 | UserADTData (DataDefName n) (DataDefParams n)
 | NatCon
 | FinCon (Atom CoreIR n)
   deriving (Show, Generic)

data NewtypeTyCon (n::S) =
   Nat
 | Fin (Atom CoreIR n)
 | EffectRowKind
 | LabeledRowKindTC
 | LabelType
 | RecordTyCon  (FieldRowElems n)
 | VariantTyCon (ExtLabeledItems (Type CoreIR n) (AtomName CoreIR n))
 | LabelCon String
 | LabeledRowCon (FieldRowElems n)
 | UserADTType SourceName (DataDefName n) (DataDefParams n)
   deriving (Show, Generic)

pattern TypeCon :: SourceName -> DataDefName n -> DataDefParams n -> CAtom n
pattern TypeCon s d xs = NewtypeTyCon (UserADTType s d xs)

pattern LabeledRow :: FieldRowElems n -> Atom CoreIR n
pattern LabeledRow xs = NewtypeTyCon (LabeledRowCon xs)

pattern RecordTy :: FieldRowElems n -> Atom CoreIR n
pattern RecordTy xs = NewtypeTyCon (RecordTyCon xs)

pattern VariantTy :: ExtLabeledItems (Type CoreIR n) (AtomName CoreIR n) -> Atom CoreIR n
pattern VariantTy xs = NewtypeTyCon (VariantTyCon xs)

isSumCon :: NewtypeCon n -> Bool
isSumCon = \case
 VariantCon _ -> True
 UserADTData _ _ -> True
 _ -> False

-- === type classes ===

data SuperclassBinders n l =
  SuperclassBinders
    { superclassBinders :: Nest (AtomNameBinder CoreIR) n l
    , superclassTypes   :: [CType n] }
  deriving (Show, Generic)

data ClassDef (n::S) where
  ClassDef
    :: SourceName
    -> [SourceName]                       -- method source names
    -> Nest RolePiBinder n1 n2            -- parameters
    ->   SuperclassBinders n2 n3          -- superclasses
    ->   [MethodType n3]                  -- method types
    -> ClassDef n1

data RolePiBinder n l = RolePiBinder (AtomNameBinder CoreIR n l) (CType n) Arrow ParamRole
     deriving (Show, Generic)

data InstanceDef (n::S) where
  InstanceDef
    :: ClassName n1
    -> Nest RolePiBinder n1 n2 -- parameters (types and dictionaries)
    ->   [CType n2]            -- class parameters
    ->   InstanceBody n2
    -> InstanceDef n1

data InstanceBody (n::S) =
  InstanceBody
    [Atom  CoreIR n]   -- superclasses dicts
    [Block CoreIR n]  -- method definitions
  deriving (Show, Generic)

data MethodType (n::S) =
  MethodType
    [Bool]     -- indicates explicit args
    (CType n)  -- actual method type
 deriving (Show, Generic)

data DictType (n::S) = DictType SourceName (ClassName n) [CType n]
     deriving (Show, Generic)

data DictExpr (n::S) =
   InstantiatedGiven (CAtom n) (NonEmpty (CAtom n))
 | SuperclassProj (CAtom n) Int  -- (could instantiate here too, but we don't need it for now)
   -- We use NonEmpty because givens without args can be represented using `Var`.
 | InstanceDict (InstanceName n) [CAtom n]
   -- Special case for `Ix (Fin n)`  (TODO: a more general mechanism for built-in classes and instances)
 | IxFin (CAtom n)
   deriving (Show, Generic)

-- TODO: Use an IntMap
newtype CustomRules (n::S) =
  CustomRules { customRulesMap :: M.Map (AtomName CoreIR n) (AtomRules n) }
  deriving (Semigroup, Monoid, Store)
data AtomRules (n::S) =
  -- number of implicit args, number of explicit args, linearization function
  CustomLinearize Int Int SymbolicZeros (CAtom n)
  deriving (Generic)

-- === Runtime representations ===

data RepVal (r::IR) (n::S) = RepVal (Type r n) (Tree (IExpr n))
     deriving (Show, Generic)

-- === envs and modules ===

-- `ModuleEnv` contains data that only makes sense in the context of evaluating
-- a particular module. `TopEnv` contains everything that makes sense "between"
-- evaluating modules.
data Env n = Env
  { topEnv    :: {-# UNPACK #-} TopEnv n
  , moduleEnv :: {-# UNPACK #-} ModuleEnv n }
  deriving (Generic)

data TopEnv (n::S) = TopEnv
  { envDefs  :: RecSubst Binding n
  , envCustomRules :: CustomRules n
  , envCache :: Cache n
  , envLoadedModules :: LoadedModules n
  , envLoadedObjects :: LoadedObjects n }
  deriving (Generic)

data SerializedEnv n = SerializedEnv
  { serializedEnvDefs        :: RecSubst Binding n
  , serializedEnvCustomRules :: CustomRules n
  , serializedEnvCache       :: Cache n }
  deriving (Generic)

-- TODO: consider splitting this further into `ModuleEnv` (the env that's
-- relevant between top-level decls) and `LocalEnv` (the additional parts of the
-- env that's relevant under a lambda binder). Unlike the Top/Module
-- distinction, there's some overlap. For example, instances can be defined at
-- both the module-level and local level. Similarly, if we start allowing
-- top-level effects in `Main` then we'll have module-level effects and local
-- effects.
data ModuleEnv (n::S) = ModuleEnv
  { envImportStatus    :: ImportStatus n
  , envSourceMap       :: SourceMap n
  , envSynthCandidates :: SynthCandidates n
  -- TODO : `CoreIR` isn't right, but we don't want `ModuleEnv` to take an IR
  -- parameter. The right thing to do is to remove `allowedEffects` from `ModuleEnv`
  -- and instead add an explicit effects reader for Inference/CheckType, where the IR
  -- parameter is known. But that's a bigger change.
  , allowedEffects     :: EffectRow CoreIR n }
  deriving (Generic)

data Module (n::S) = Module
  { moduleSourceName :: ModuleSourceName
  , moduleDirectDeps :: S.Set (ModuleName n)
  , moduleTransDeps  :: S.Set (ModuleName n)  -- XXX: doesn't include the module itself
  , moduleExports    :: SourceMap n
    -- these are just the synth candidates required by this
    -- module by itself. We'll usually also need those required by the module's
    -- (transitive) dependencies, which must be looked up separately.
  , moduleSynthCandidates :: SynthCandidates n }
  deriving (Show, Generic)

data LoadedModules (n::S) = LoadedModules
  { fromLoadedModules   :: M.Map ModuleSourceName (ModuleName n)}
  deriving (Show, Generic)

emptyModuleEnv :: ModuleEnv n
emptyModuleEnv = ModuleEnv emptyImportStatus (SourceMap mempty) mempty Pure

emptyLoadedModules :: LoadedModules n
emptyLoadedModules = LoadedModules mempty

data LoadedObjects (n::S) = LoadedObjects
  -- the pointer points to the actual runtime function
  { fromLoadedObjects :: M.Map (FunObjCodeName n) NativeFunction}
  deriving (Show, Generic)

emptyLoadedObjects :: LoadedObjects n
emptyLoadedObjects = LoadedObjects mempty

data ImportStatus (n::S) = ImportStatus
  { directImports :: S.Set (ModuleName n)
    -- XXX: This are cached for efficiency. It's derivable from `directImports`.
  , transImports           :: S.Set (ModuleName n) }
  deriving (Show, Generic)

data TopEnvFrag n l = TopEnvFrag (EnvFrag n l) (PartialTopEnvFrag l)

-- This is really the type of updates to `Env`. We should probably change the
-- names to reflect that.
data PartialTopEnvFrag n = PartialTopEnvFrag
  { fragCache           :: Cache n
  , fragCustomRules     :: CustomRules n
  , fragLoadedModules   :: LoadedModules n
  , fragLoadedObjects   :: LoadedObjects n
  , fragLocalModuleEnv  :: ModuleEnv n
  , fragFinishSpecializedDict :: SnocList (SpecDictName n, [LamExpr SimpIR n])
  , fragTopFunUpdates         :: SnocList (TopFunName n, TopFunEvalStatus n) }

-- TODO: we could add a lot more structure for querying by dict type, caching, etc.
-- TODO: make these `Name n` instead of `Atom n` so they're usable as cache keys.
data SynthCandidates n = SynthCandidates
  { lambdaDicts       :: [AtomName CoreIR n]
  , instanceDicts     :: M.Map (ClassName n) [InstanceName n] }
  deriving (Show, Generic)

emptyImportStatus :: ImportStatus n
emptyImportStatus = ImportStatus mempty mempty

-- TODO: figure out the additional top-level context we need -- backend, other
-- compiler flags etc. We can have a map from those to this.

data Cache (n::S) = Cache
  { specializationCache :: EMap SpecializationSpec TopFunName n
  , ixDictCache :: EMap AbsDict SpecDictName n
  , linearizationCache :: EMap LinearizationSpec (PairE TopFunName TopFunName) n
    -- This is memoizing `parseAndGetDeps :: Text -> [ModuleSourceName]`. But we
    -- only want to store one entry per module name as a simple cache eviction
    -- policy, so we store it keyed on the module name, with the text hash for
    -- the validity check.
  , parsedDeps :: M.Map ModuleSourceName (FileHash, [ModuleSourceName])
  , moduleEvaluations :: M.Map ModuleSourceName ((FileHash, [ModuleName n]), ModuleName n)
  } deriving (Show, Generic)

updateEnv :: Color c => Name c n -> Binding c n -> Env n -> Env n
updateEnv v rhs env =
  env { topEnv = (topEnv env) { envDefs = RecSubst $ updateSubstFrag v rhs bs } }
  where (RecSubst bs) = envDefs $ topEnv env

-- === runtime function and variable representations ===

type RuntimeEnv = DynamicVarKeyPtrs

type DexDestructor = FunPtr (IO ())

data NativeFunction = NativeFunction
  { nativeFunPtr      :: FunPtr ()
  , nativeFunTeardown :: IO () }

instance Show NativeFunction where
  show _ = "<native function>"

-- Holds pointers to thread-local storage used to simulate dynamically scoped
-- variables, such as the output stream file descriptor.
type DynamicVarKeyPtrs = [(DynamicVar, Ptr ())]

data DynamicVar = OutStreamDyvar -- TODO: add others as needed
                  deriving (Enum, Bounded)

dynamicVarCName :: DynamicVar -> String
dynamicVarCName OutStreamDyvar = "dex_out_stream_dyvar"

dynamicVarLinkMap :: DynamicVarKeyPtrs -> [(String, Ptr ())]
dynamicVarLinkMap dyvars = dyvars <&> \(v, ptr) -> (dynamicVarCName v, ptr)

-- === bindings - static information we carry about a lexical scope ===

-- TODO: consider making this an open union via a typeable-like class
data Binding (c::C) (n::S) where
  AtomNameBinding   :: AtomBinding r n                 -> Binding (AtomNameC r)   n
  DataDefBinding    :: DataDef n                       -> Binding DataDefNameC    n
  TyConBinding      :: DataDefName n        -> CAtom n -> Binding TyConNameC      n
  DataConBinding    :: DataDefName n -> Int -> CAtom n -> Binding DataConNameC    n
  ClassBinding      :: ClassDef n                      -> Binding ClassNameC      n
  InstanceBinding   :: InstanceDef n                   -> Binding InstanceNameC   n
  MethodBinding     :: ClassName n   -> Int -> CAtom n -> Binding MethodNameC     n
  EffectBinding     :: EffectDef n                    -> Binding EffectNameC     n
  HandlerBinding    :: HandlerDef n                   -> Binding HandlerNameC    n
  EffectOpBinding   :: EffectOpDef n                  -> Binding EffectOpNameC   n
  TopFunBinding     :: TopFun n                       -> Binding TopFunNameC     n
  FunObjCodeBinding :: FunObjCode -> LinktimeNames n  -> Binding FunObjCodeNameC n
  ModuleBinding     :: Module n                       -> Binding ModuleNameC     n
  -- TODO: add a case for abstracted pointers, as used in `ClosedImpFunction`
  PtrBinding        :: PtrType -> PtrLitVal           -> Binding PtrNameC        n
  SpecializedDictBinding :: SpecializedDictDef n      -> Binding SpecializedDictNameC n
  ImpNameBinding    :: BaseType                       -> Binding ImpNameC n

data EffectOpDef (n::S) where
  EffectOpDef :: EffectName n  -- name of associated effect
              -> EffectOpIdx   -- index in effect definition
              -> EffectOpDef n
  deriving (Show, Generic)

instance GenericE EffectOpDef where
  type RepE EffectOpDef =
    EffectName `PairE` LiftE EffectOpIdx
  fromE (EffectOpDef name idx) = name `PairE` LiftE idx
  toE (name `PairE` LiftE idx) = EffectOpDef name idx

instance SinkableE   EffectOpDef
instance HoistableE  EffectOpDef
instance RenameE     EffectOpDef

data EffectOpIdx = ReturnOp | OpIdx Int
  deriving (Show, Eq, Generic)

data EffectDef (n::S) where
  EffectDef :: SourceName
            -> [(SourceName, EffectOpType n)]
            -> EffectDef n

instance GenericE EffectDef where
  type RepE EffectDef =
    LiftE SourceName `PairE` ListE (LiftE SourceName `PairE` EffectOpType)
  fromE (EffectDef name ops) =
    LiftE name `PairE` ListE (map (\(x, y) -> LiftE x `PairE` y) ops)
  toE (LiftE name `PairE` ListE ops) =
    EffectDef name (map (\(LiftE x `PairE` y)->(x,y)) ops)

instance SinkableE EffectDef
instance HoistableE  EffectDef
instance AlphaEqE EffectDef
instance AlphaHashableE EffectDef
instance RenameE     EffectDef
deriving instance Show (EffectDef n)
deriving via WrapE EffectDef n instance Generic (EffectDef n)

data HandlerDef (n::S) where
  HandlerDef :: EffectName n
             -> PiBinder n r -- body type arg
             -> Nest PiBinder r l
               -> EffectRow CoreIR l
               -> CType l          -- return type
               -> [Block CoreIR l] -- effect operations
               -> Block CoreIR l   -- return body
             -> HandlerDef n

instance GenericE HandlerDef where
  type RepE HandlerDef =
    EffectName `PairE` Abs (PiBinder `PairB` Nest PiBinder)
      (EffectRow CoreIR `PairE` CType `PairE` ListE (Block CoreIR) `PairE` Block CoreIR)
  fromE (HandlerDef name bodyTyArg bs effs ty ops ret) =
    name `PairE` Abs (bodyTyArg `PairB` bs) (effs `PairE` ty `PairE` ListE ops `PairE` ret)
  toE (name `PairE` Abs (bodyTyArg `PairB` bs) (effs `PairE` ty `PairE` ListE ops `PairE` ret)) =
    HandlerDef name bodyTyArg bs effs ty ops ret

instance SinkableE HandlerDef
instance HoistableE  HandlerDef
instance AlphaEqE HandlerDef
instance AlphaHashableE HandlerDef
instance RenameE     HandlerDef
deriving instance Show (HandlerDef n)
deriving via WrapE HandlerDef n instance Generic (HandlerDef n)

data EffectOpType (n::S) where
  EffectOpType :: UResumePolicy -> CType n -> EffectOpType n

instance GenericE EffectOpType where
  type RepE EffectOpType =
    LiftE UResumePolicy `PairE` CType
  fromE (EffectOpType pol ty) = LiftE pol `PairE` ty
  toE (LiftE pol `PairE` ty) = EffectOpType pol ty

instance SinkableE EffectOpType
instance HoistableE  EffectOpType
instance AlphaEqE EffectOpType
instance AlphaHashableE EffectOpType
instance RenameE     EffectOpType
deriving instance Show (EffectOpType n)
deriving via WrapE EffectOpType n instance Generic (EffectOpType n)

instance GenericE SpecializedDictDef where
  type RepE SpecializedDictDef = AbsDict `PairE` MaybeE (ListE (LamExpr SimpIR))
  fromE (SpecializedDict ab methods) = ab `PairE` methods'
    where methods' = case methods of Just xs -> LeftE (ListE xs)
                                     Nothing -> RightE UnitE
  {-# INLINE fromE #-}
  toE   (ab `PairE` methods) = SpecializedDict ab methods'
    where methods' = case methods of LeftE (ListE xs) -> Just xs
                                     RightE UnitE     -> Nothing
  {-# INLINE toE #-}

instance SinkableE      SpecializedDictDef
instance HoistableE     SpecializedDictDef
instance AlphaEqE       SpecializedDictDef
instance AlphaHashableE SpecializedDictDef
instance RenameE        SpecializedDictDef

data EvalStatus a = Waiting | Running | Finished a
     deriving (Show, Eq, Ord, Generic, Functor, Foldable, Traversable)
type TopFunEvalStatus n = EvalStatus (TopFunLowerings n)

data TopFun (n::S) =
   DexTopFun (TopFunDef n) (NaryPiType SimpIR n) (LamExpr SimpIR n) (TopFunEvalStatus n)
 | FFITopFun String IFunType
   deriving (Show, Generic)

data TopFunDef (n::S) =
   Specialization       (SpecializationSpec n)
 | LinearizationPrimal  (LinearizationSpec n)
 | LinearizationTangent (LinearizationSpec n)
   deriving (Show, Generic)

newtype TopFunLowerings (n::S) = TopFunLowerings
  { topFunObjCode :: FunObjCodeName n } -- TODO: add optimized, imp etc. as needed
  deriving (Show, Generic, SinkableE, HoistableE, RenameE, AlphaEqE, AlphaHashableE, Pretty)

data AtomBinding (r::IR) (n::S) where
 LetBound     :: DeclBinding r  n  -> AtomBinding r n
 MiscBound    :: Type        r  n  -> AtomBinding r n
 TopDataBound :: RepVal SimpIR n   -> AtomBinding SimpIR n
 LamBound     :: LamBinding  n     -> AtomBinding CoreIR n
 PiBound      :: PiBinding   n     -> AtomBinding CoreIR n
 SolverBound  :: SolverBinding n   -> AtomBinding CoreIR n
 NoinlineFun  :: NoInlineDef n     -> AtomBinding CoreIR n
 FFIFunBound  :: NaryPiType CoreIR n -> TopFunName n -> AtomBinding CoreIR n

deriving instance IRRep r => Show (AtomBinding r n)
deriving via WrapE (AtomBinding r) n instance IRRep r => Generic (AtomBinding r n)

atomBindingType :: AtomBinding r n -> Type r n
atomBindingType b = case b of
  LetBound    (DeclBinding _ ty _) -> ty
  LamBound    (LamBinding  _ ty)   -> ty
  PiBound     (PiBinding   _ ty)   -> ty
  MiscBound   ty                   -> ty
  SolverBound (InfVarBound ty _)   -> ty
  SolverBound (SkolemBound ty)     -> ty
  NoinlineFun (NoInlineDef _ _ _ ty _) -> ty
  TopDataBound (RepVal ty _) -> ty
  FFIFunBound piTy _ -> naryPiTypeAsType piTy

data NoInlineDef n = NoInlineDef Int [Arrow] (NaryPiType CoreIR n) (CType n) (CAtom n)
     deriving (Show, Generic)

-- TODO: Move this to Inference!
data SolverBinding (n::S) =
   InfVarBound (CType n) SrcPosCtx
 | SkolemBound (CType n)
   deriving (Show, Generic)

data EnvFrag (n::S) (l::S) =
  EnvFrag (RecSubstFrag Binding n l) (Maybe (EffectRow CoreIR l))

instance HasScope Env where
  toScope = toScope . envDefs . topEnv

catEnvFrags :: Distinct n3
                 => EnvFrag n1 n2 -> EnvFrag n2 n3 -> EnvFrag n1 n3
catEnvFrags (EnvFrag frag1 maybeEffs1)
                 (EnvFrag frag2 maybeEffs2) =
  withExtEvidence (toExtEvidence frag2) do
    let fragOut = catRecSubstFrags frag1 frag2
    let effsOut = case maybeEffs2 of
                     Nothing    -> fmap sink maybeEffs1
                     Just effs2 -> Just effs2
    EnvFrag fragOut effsOut

instance OutFrag EnvFrag where
  emptyOutFrag = EnvFrag emptyOutFrag Nothing
  {-# INLINE emptyOutFrag #-}
  catOutFrags frag1 frag2 = catEnvFrags frag1 frag2
  {-# INLINE catOutFrags #-}

instance OutMap Env where
  emptyOutMap =
    Env (TopEnv (RecSubst emptyInFrag) mempty mempty emptyLoadedModules emptyLoadedObjects)
        emptyModuleEnv
  {-# INLINE emptyOutMap #-}

instance ExtOutMap Env (RecSubstFrag Binding)  where
  -- TODO: We might want to reorganize this struct to make this
  -- do less explicit sinking etc. It's a hot operation!
  extendOutMap (Env (TopEnv defs rules cache loadedM loadedO)
                    (ModuleEnv imports sm scs effs)) frag =
    withExtEvidence frag $ Env
      (TopEnv
        (defs  `extendRecSubst` frag)
        (sink rules)
        (sink cache)
        (sink loadedM)
        (sink loadedO))
      (ModuleEnv
        (sink imports)
        (sink sm)
        (sink scs <> bindingsFragToSynthCandidates (EnvFrag frag Nothing))
        (sink effs))
  {-# INLINE extendOutMap #-}

instance ExtOutMap Env EnvFrag where
  extendOutMap = extendEnv
  {-# INLINE extendOutMap #-}

extendEnv :: Distinct l => Env n -> EnvFrag n l -> Env l
extendEnv env (EnvFrag newEnv maybeNewEff) = do
  case extendOutMap env newEnv of
    Env envTop (ModuleEnv imports sm scs oldEff) -> do
      let newEff = case maybeNewEff of
                     Nothing  -> sink oldEff
                     Just eff -> eff
      Env envTop (ModuleEnv imports sm scs newEff)
{-# NOINLINE [1] extendEnv #-}

bindingsFragToSynthCandidates :: Distinct l => EnvFrag n l -> SynthCandidates l
bindingsFragToSynthCandidates (EnvFrag (RecSubstFrag frag) _) =
  execWriter $ go $ toSubstPairs frag
  where
    go :: Distinct l
       => Nest (SubstPair Binding l) n l -> Writer (SynthCandidates l) ()
    go nest = case nest of
      Empty -> return ()
      Nest (SubstPair b binding) rest -> withExtEvidence rest do
        case binding of
           AtomNameBinding (LamBound (LamBinding ClassArrow _)) -> do
             tell $ sink (SynthCandidates [binderName b] mempty)
           AtomNameBinding (PiBound (PiBinding ClassArrow _)) -> do
             tell $ sink (SynthCandidates [binderName b] mempty)
           _ -> return ()
        go rest

naryPiTypeAsType :: NaryPiType CoreIR n -> Type CoreIR n
naryPiTypeAsType (NaryPiType Empty Pure resultTy) = resultTy
naryPiTypeAsType (NaryPiType (Nest (b:>ty) bs) effs resultTy) = case bs of
  Empty -> Pi $ PiType (PiBinder b ty PlainArrow) effs resultTy
  Nest _ _ -> Pi $ PiType (PiBinder b ty PlainArrow) Pure $ naryPiTypeAsType $ NaryPiType bs effs resultTy
naryPiTypeAsType _ = error "Effectful naryPiType should have at least one argument"

-- === effects ===

data Effect (r::IR) (n::S) =
   RWSEffect RWS (Atom r n)
 | ExceptionEffect
 | IOEffect
 | UserEffect (Name EffectNameC n)
 | InitEffect
 deriving (Generic, Show)

data EffectRow (r::IR) (n::S) =
  EffectRow (ESet (Effect r) n) (EffectRowTail r n)
  deriving (Generic)

data EffectRowTail (r::IR) (n::S) where
  EffectRowTail :: AtomName CoreIR n -> EffectRowTail CoreIR n
  NoTail        ::                      EffectRowTail r n
deriving instance IRRep r => Show (EffectRowTail r n)
deriving instance IRRep r => Eq   (EffectRowTail r n)
deriving via WrapE (EffectRowTail r) n instance IRRep r => Generic (EffectRowTail r n)

deriving instance IRRep r => Show (EffectRow r n)

pattern Pure :: IRRep r => EffectRow r n
pattern Pure <- ((\(EffectRow effs t) -> (eSetToList effs, t)) -> ([], NoTail))
  where Pure = EffectRow mempty NoTail

pattern OneEffect :: IRRep r => Effect r n -> EffectRow r n
pattern OneEffect eff <- ((\(EffectRow effs t) -> (eSetToList effs, t)) -> ([eff], NoTail))
  where OneEffect eff = EffectRow (eSetSingleton eff) NoTail

instance IRRep r => Semigroup (EffectRow r n) where
  EffectRow effs t <> EffectRow effs' t' =
    EffectRow (effs <> effs') newTail
    where
      newTail = case (t, t') of
        (NoTail, effTail) -> effTail
        (effTail, NoTail) -> effTail
        _ | t == t' -> t
          | otherwise -> error "Can't combine effect rows with mismatched tails"

instance IRRep r => Monoid (EffectRow r n) where
  mempty = EffectRow mempty NoTail

extendEffRow :: IRRep r => ESet (Effect r) n -> EffectRow r n -> EffectRow r n
extendEffRow effs (EffectRow effs' t) = EffectRow (effs <> effs') t
{-# INLINE extendEffRow #-}

instance IRRep r => Store (EffectRowTail r n)
instance IRRep r => Store (EffectRow     r n)
instance IRRep r => Store (Effect        r n)

data EffectBinder n l where
  EffectBinder :: EffectRow CoreIR n -> EffectBinder n n

instance  GenericB EffectBinder where
  type RepB EffectBinder = LiftB (EffectRow CoreIR)
  fromB (EffectBinder effs) = LiftB effs
  toB   (LiftB effs) = EffectBinder effs

instance SinkableB EffectBinder
instance HoistableB EffectBinder
instance ProvesExt  EffectBinder
instance BindsNames EffectBinder
instance RenameB     EffectBinder

-- === Specialization and generalization ===

type Generalized (r::IR) (e::E) (n::S) = (Abstracted r e n, [Atom r n])
type Abstracted (r::IR) (e::E) = Abs (Nest (Binder r)) e
type AbsDict = Abstracted CoreIR Dict

data SpecializedDictDef n =
   SpecializedDict
     (AbsDict n)
     -- Methods (thunked if nullary), if they're available.
     -- We create specialized dict names during simplification, but we don't
     -- actually simplify/lower them until we return to TopLevel
     (Maybe [LamExpr SimpIR n])
   deriving (Show, Generic)

-- TODO: extend with AD-oriented specializations, backend-specific specializations etc.
data SpecializationSpec (n::S) =
   AppSpecialization (AtomName CoreIR n) (Abstracted CoreIR (ListE CType) n)
   deriving (Show, Generic)

type Active = Bool
data LinearizationSpec (n::S) =
  LinearizationSpec (TopFunName n) [Active]
  deriving (Show, Generic)

-- === BindsOneAtomName ===

-- We're really just defining this so we can have a polymorphic `binderType`.
-- But maybe we don't need one. Or maybe we can make one using just
-- `BindsOneName b AtomNameC` and `BindsEnv b`.
class BindsOneName b (AtomNameC r) => BindsOneAtomName (r::IR) (b::B) | b -> r where
  binderType :: b n l -> Type r n
  -- binderAtomName :: b n l -> AtomName r l

bindersTypes :: (IRRep r, Distinct l, ProvesExt b, BindsNames b, BindsOneAtomName r b)
             => Nest b n l -> [Type r l]
bindersTypes Empty = []
bindersTypes n@(Nest b bs) = ty : bindersTypes bs
  where ty = withExtEvidence n $ sink (binderType b)

instance IRRep r => BindsOneAtomName r (BinderP (AtomNameC r) (Type r)) where
  binderType (_ :> ty) = ty

instance BindsOneAtomName CoreIR PiBinder where
  binderType (PiBinder _ ty _) = ty

instance IRRep r => BindsOneAtomName r (IxBinder r) where
  binderType (_ :> IxType ty _) = ty

instance BindsOneAtomName CoreIR RolePiBinder where
  binderType (RolePiBinder _ ty _ _) = ty

toBinderNest :: BindsOneAtomName r b => Nest b n l -> Nest (Binder r) n l
toBinderNest Empty = Empty
toBinderNest (Nest b bs) = Nest (asNameBinder b :> binderType b) (toBinderNest bs)

-- === ToBinding ===

atomBindingToBinding :: AtomBinding r n -> Binding (AtomNameC r) n
atomBindingToBinding b = AtomNameBinding b

bindingToAtomBinding :: Binding (AtomNameC r) n -> AtomBinding r n
bindingToAtomBinding (AtomNameBinding b) = b

class (RenameE     e, SinkableE e) => ToBinding (e::E) (c::C) | e -> c where
  toBinding :: e n -> Binding c n

instance Color c => ToBinding (Binding c) c where
  toBinding = id

instance IRRep r => ToBinding (AtomBinding r) (AtomNameC r) where
  toBinding = atomBindingToBinding

instance IRRep r => ToBinding (DeclBinding r) (AtomNameC r) where
  toBinding = toBinding . LetBound

instance ToBinding LamBinding (AtomNameC CoreIR) where
  toBinding = toBinding . LamBound

instance ToBinding PiBinding (AtomNameC CoreIR) where
  toBinding = toBinding . PiBound

instance IRRep r => ToBinding (Atom r) (AtomNameC r) where
  toBinding = toBinding . MiscBound

instance ToBinding SolverBinding (AtomNameC CoreIR) where
  toBinding = toBinding . SolverBound

instance IRRep r => ToBinding (IxType r) (AtomNameC r) where
  toBinding (IxType t _) = toBinding t

instance (ToBinding e1 c, ToBinding e2 c) => ToBinding (EitherE e1 e2) c where
  toBinding (LeftE  e) = toBinding e
  toBinding (RightE e) = toBinding e

-- === HasArgType ===

class HasArgType (e::E) (r::IR) | e -> r where
  argType :: e n -> Type r n

instance HasArgType PiType CoreIR where
  argType (PiType (PiBinder _ ty _) _ _) = ty

instance HasArgType (TabPiType r) r where
  argType (TabPiType (_:>IxType ty _) _) = ty

-- === Pattern synonyms ===

pattern IdxRepScalarBaseTy :: ScalarBaseType
pattern IdxRepScalarBaseTy = Word32Type

-- Type used to represent indices and sizes at run-time
pattern IdxRepTy :: Type r n
pattern IdxRepTy = TC (BaseType (Scalar Word32Type))

pattern IdxRepVal :: Word32 -> Atom r n
pattern IdxRepVal x = Con (Lit (Word32Lit x))

pattern IIdxRepVal :: Word32 -> IExpr n
pattern IIdxRepVal x = ILit (Word32Lit x)

pattern IIdxRepTy :: IType
pattern IIdxRepTy = Scalar Word32Type

-- Type used to represent sum type tags at run-time
pattern TagRepTy :: Type r n
pattern TagRepTy = TC (BaseType (Scalar Word8Type))

pattern TagRepVal :: Word8 -> Atom r n
pattern TagRepVal x = Con (Lit (Word8Lit x))

pattern CharRepTy :: Type r n
pattern CharRepTy = Word8Ty

charRepVal :: Char -> Atom r n
charRepVal c = Con (Lit (Word8Lit (fromIntegral $ fromEnum c)))

pattern Word8Ty :: Type r n
pattern Word8Ty = TC (BaseType (Scalar Word8Type))

pattern ProdTy :: [Type r n] -> Type r n
pattern ProdTy tys = TC (ProdType tys)

pattern ProdVal :: [Atom r n] -> Atom r n
pattern ProdVal xs = Con (ProdCon xs)

pattern Record :: LabeledItems () -> [Atom CoreIR n] -> Atom CoreIR n
pattern Record ty xs = NewtypeCon (RecordCon ty) (ProdVal xs)

pattern SumTy :: [Type r n] -> Type r n
pattern SumTy cs = TC (SumType cs)

pattern SumVal :: [Type r n] -> Int -> Atom r n -> Atom r n
pattern SumVal tys tag payload = Con (SumCon tys tag payload)

pattern PairVal :: Atom r n -> Atom r n -> Atom r n
pattern PairVal x y = Con (ProdCon [x, y])

pattern PairTy :: Type r n -> Type r n -> Type r n
pattern PairTy x y = TC (ProdType [x, y])

pattern UnitVal :: Atom r n
pattern UnitVal = Con (ProdCon [])

pattern UnitTy :: Type r n
pattern UnitTy = TC (ProdType [])

pattern BaseTy :: BaseType -> Type r n
pattern BaseTy b = TC (BaseType b)

pattern PtrTy :: PtrType -> Type r n
pattern PtrTy ty = BaseTy (PtrType ty)

pattern RefTy :: Atom r n -> Type r n -> Type r n
pattern RefTy r a = TC (RefType r a)

pattern RawRefTy :: Type r n -> Type r n
pattern RawRefTy a = TC (RefType (Con HeapVal) a)

pattern TabTy :: IxBinder r n l -> Type r l -> Type r n
pattern TabTy b body = TabPi (TabPiType b body)

pattern FinTy :: Atom CoreIR n -> Type CoreIR n
pattern FinTy n = NewtypeTyCon (Fin n)

pattern NatTy :: Type CoreIR n
pattern NatTy = NewtypeTyCon Nat

pattern NatVal :: Word32 -> Atom CoreIR n
pattern NatVal n = NewtypeCon NatCon (IdxRepVal n)

pattern TyKind :: Kind r n
pattern TyKind = TC TypeKind

pattern EffKind :: Kind CoreIR n
pattern EffKind = NewtypeTyCon EffectRowKind

pattern LabeledRowKind :: Kind CoreIR n
pattern LabeledRowKind = NewtypeTyCon LabeledRowKindTC

pattern FinConst :: Word32 -> Type CoreIR n
pattern FinConst n = NewtypeTyCon (Fin (NatVal n))

pattern NullaryLamExpr :: Block r n -> LamExpr r n
pattern NullaryLamExpr body = LamExpr Empty body

pattern UnaryLamExpr :: Binder r n l -> Block r l -> LamExpr r n
pattern UnaryLamExpr b body = LamExpr (UnaryNest b) body

pattern BinaryLamExpr :: Binder r n l1 -> Binder r l1 l2 -> Block r l2 -> LamExpr r n
pattern BinaryLamExpr b1 b2 body = LamExpr (BinaryNest b1 b2) body

pattern NullaryDestLamExpr :: DestBlock r n -> DestLamExpr r n
pattern NullaryDestLamExpr body = DestLamExpr Empty body

pattern BinaryFunTy :: PiBinder n l1 -> PiBinder l1 l2 -> EffectRow r l2 -> CType l2 -> CType n
pattern BinaryFunTy b1 b2 eff ty <- Pi (PiType b1 Pure (Pi (PiType b2 eff ty)))

pattern AtomicBlock :: Atom r n -> Block r n
pattern AtomicBlock atom <- Block _ Empty atom
  where AtomicBlock atom = Block NoBlockAnn Empty atom

exprBlock :: IRRep r => Block r n -> Maybe (Expr r n)
exprBlock (Block _ (Nest (Let b (DeclBinding _ _ expr)) Empty) (Var n))
  | n == binderName b = Just expr
exprBlock _ = Nothing
{-# INLINE exprBlock #-}

pattern MaybeTy :: Type r n -> Type r n
pattern MaybeTy a = SumTy [UnitTy, a]

pattern NothingAtom :: Type r n -> Atom r n
pattern NothingAtom a = SumVal [UnitTy, a] 0 UnitVal

pattern JustAtom :: Type r n -> Atom r n -> Atom r n
pattern JustAtom a x = SumVal [UnitTy, a] 1 x

pattern BoolTy :: Type r n
pattern BoolTy = Word8Ty

pattern FalseAtom :: Atom r n
pattern FalseAtom = Con (Lit (Word8Lit 0))

pattern TrueAtom :: Atom r n
pattern TrueAtom = Con (Lit (Word8Lit 1))

fieldRowElemsFromList :: [FieldRowElem n] -> FieldRowElems n
fieldRowElemsFromList = foldr prependFieldRowElem (UnsafeFieldRowElems [])

prependFieldRowElem :: FieldRowElem n -> FieldRowElems n -> FieldRowElems n
prependFieldRowElem e (UnsafeFieldRowElems els) = case e of
  DynField  _ _ -> UnsafeFieldRowElems $ e : els
  DynFields _   -> UnsafeFieldRowElems $ e : els
  StaticFields items | null items -> UnsafeFieldRowElems els
  StaticFields items -> case els of
    (StaticFields items':rest) -> UnsafeFieldRowElems $ StaticFields (items <> items') : rest
    _                          -> UnsafeFieldRowElems $ e : els

extRowAsFieldRowElems :: ExtLabeledItems (CType n) (CAtomName n) -> FieldRowElems n
extRowAsFieldRowElems (Ext items ext) = UnsafeFieldRowElems $ itemsEl ++ extEl
  where
    itemsEl = if null items then [] else [StaticFields items]
    extEl = case ext of Nothing -> []; Just r -> [DynFields r]

fieldRowElemsAsExtRow
  :: Alternative f => FieldRowElems n -> f (ExtLabeledItems (CType n) (CAtomName  n))
fieldRowElemsAsExtRow (UnsafeFieldRowElems els) = case els of
  []                                -> pure $ Ext mempty Nothing
  [DynFields r]                     -> pure $ Ext mempty (Just r)
  [StaticFields items]              -> pure $ Ext items  Nothing
  [StaticFields items, DynFields r] -> pure $ Ext items  (Just r)
  _ -> empty

getAtMostSingleStatic :: NewtypeTyCon n -> Maybe (LabeledItems (CType n))
getAtMostSingleStatic = \case
  RecordTyCon (UnsafeFieldRowElems els) -> case els of
    [] -> Just mempty
    [StaticFields items] -> Just items
    _ -> Nothing
  _ -> Nothing

pattern StaticRecordTy :: LabeledItems (CType n) -> Type CoreIR n
pattern StaticRecordTy items = NewtypeTyCon (StaticRecordTyCon items)

pattern StaticRecordTyCon :: LabeledItems (Type CoreIR n) -> NewtypeTyCon n
pattern StaticRecordTyCon items <- (getAtMostSingleStatic -> Just items)
  where StaticRecordTyCon items = RecordTyCon (fieldRowElemsFromList [StaticFields items])

pattern RecordTyWithElems :: [FieldRowElem n] -> Atom CoreIR n
pattern RecordTyWithElems elems <- RecordTy (UnsafeFieldRowElems elems)
  where RecordTyWithElems elems = RecordTy $ fieldRowElemsFromList elems

-- === Typeclass instances for Name and other Haskell libraries ===

instance GenericE AtomRules where
  type RepE AtomRules = (LiftE (Int, Int, SymbolicZeros)) `PairE` CAtom
  fromE (CustomLinearize ni ne sz a) = LiftE (ni, ne, sz) `PairE` a
  toE (LiftE (ni, ne, sz) `PairE` a) = CustomLinearize ni ne sz a
instance SinkableE AtomRules
instance HoistableE AtomRules
instance AlphaEqE AtomRules
instance RenameE     AtomRules

instance IRRep r => GenericE (RepVal r) where
  type RepE (RepVal r) = PairE (Type r) (ComposeE Tree IExpr)
  fromE (RepVal ty tree) = ty `PairE` ComposeE tree
  toE   (ty `PairE` ComposeE tree) = RepVal ty tree

instance IRRep r => SinkableE      (RepVal r)
instance IRRep r => RenameE        (RepVal r)
instance IRRep r => HoistableE     (RepVal r)
instance IRRep r => AlphaHashableE (RepVal r)
instance IRRep r => AlphaEqE       (RepVal r)

instance GenericE CustomRules where
  type RepE CustomRules = ListE (PairE (AtomName CoreIR) AtomRules)
  fromE (CustomRules m) = ListE $ toPairE <$> M.toList m
  toE (ListE l) = CustomRules $ M.fromList $ fromPairE <$> l
instance SinkableE CustomRules
instance HoistableE CustomRules
instance AlphaEqE CustomRules
instance RenameE     CustomRules

instance GenericE DataDefParams where
  type RepE DataDefParams = ListE (PairE (LiftE Arrow) CAtom)
  fromE (DataDefParams xs) = ListE $ map toPairE $ map (onFst LiftE) xs
  {-# INLINE fromE #-}
  toE (ListE xs) = DataDefParams $ map (onFst fromLiftE) $ map fromPairE xs
  {-# INLINE toE #-}

-- We ignore the dictionary parameters because we assume coherence
instance AlphaEqE DataDefParams where
  alphaEqE (DataDefParams params) (DataDefParams params') =
    alphaEqE (ListE $ plainArrows params) (ListE $ plainArrows params')

instance AlphaHashableE DataDefParams where
  hashWithSaltE env salt (DataDefParams params) =
    hashWithSaltE env salt (ListE $ plainArrows params)

instance SinkableE           DataDefParams
instance HoistableE          DataDefParams
instance RenameE             DataDefParams

instance GenericE DataDef where
  type RepE DataDef = PairE (LiftE SourceName) (Abs (Nest RolePiBinder) (ListE DataConDef))
  fromE (DataDef sourceName bs cons) = PairE (LiftE sourceName) (Abs bs (ListE cons))
  {-# INLINE fromE #-}
  toE   (PairE (LiftE sourceName) (Abs bs (ListE cons))) = DataDef sourceName bs cons
  {-# INLINE toE #-}

deriving instance Show (DataDef n)
deriving via WrapE DataDef n instance Generic (DataDef n)
instance SinkableE DataDef
instance HoistableE  DataDef
instance RenameE     DataDef
instance AlphaEqE DataDef
instance AlphaHashableE DataDef

instance GenericE DataConDef where
  type RepE DataConDef = (LiftE (SourceName, [[Projection]])) `PairE` Type CoreIR
  fromE (DataConDef name repTy idxs) = (LiftE (name, idxs)) `PairE` repTy
  {-# INLINE fromE #-}
  toE   ((LiftE (name, idxs)) `PairE` repTy) = DataConDef name repTy idxs
  {-# INLINE toE #-}
instance SinkableE      DataConDef
instance HoistableE     DataConDef
instance RenameE        DataConDef
instance AlphaEqE       DataConDef
instance AlphaHashableE DataConDef

instance GenericE NewtypeCon where
  type RepE NewtypeCon = EitherE5
   {- RecordCon -}    (LiftE (LabeledItems ()))
   {- VariantCon -}   (LiftE (LabeledItems ()))
   {- UserADTData -}  (DataDefName `PairE` DataDefParams)
   {- NatCon -}       UnitE
   {- FinCon -}       CAtom
  fromE = \case
    RecordCon  l    -> Case0 $ LiftE l
    VariantCon l    -> Case1 $ LiftE l
    UserADTData d p -> Case2 $ d `PairE` p
    NatCon          -> Case3 UnitE
    FinCon n        -> Case4 n
  {-# INLINE fromE #-}
  toE = \case
    Case0 (LiftE l)     -> RecordCon  l
    Case1 (LiftE l)     -> VariantCon l
    Case2 (d `PairE` p) -> UserADTData d p
    Case3 UnitE         -> NatCon
    Case4 n             -> FinCon n
    _ -> error "impossible"
  {-# INLINE toE #-}

instance SinkableE      NewtypeCon
instance HoistableE     NewtypeCon
instance AlphaEqE       NewtypeCon
instance AlphaHashableE NewtypeCon
instance RenameE        NewtypeCon

instance GenericE NewtypeTyCon where
  type RepE NewtypeTyCon = EitherE2
           ( EitherE5
    {- Nat -}              UnitE
    {- Fin -}              CAtom
    {- EffectRowKind -}    UnitE
    {- LabeledRowKindTC -} UnitE
    {- LabelType -}        UnitE
         ) ( EitherE5
    {- RecordTyCon -}      FieldRowElems
    {- VariantTyCon  -}    (ExtLabeledItemsE (Type CoreIR) (AtomName CoreIR))
    {- LabelCon -}         (LiftE String)
    {- LabeledRowCon -}    FieldRowElems
    {- UserADTType -}      (LiftE SourceName `PairE` DataDefName `PairE` DataDefParams)
         )
  fromE = \case
    Nat               -> Case0 $ Case0 UnitE
    Fin n             -> Case0 $ Case1 n
    EffectRowKind     -> Case0 $ Case2 UnitE
    LabeledRowKindTC  -> Case0 $ Case3 UnitE
    LabelType         -> Case0 $ Case4 UnitE
    RecordTyCon   xs  -> Case1 $ Case0 xs
    VariantTyCon  xs  -> Case1 $ Case1 $ ExtLabeledItemsE xs
    LabelCon      s   -> Case1 $ Case2 (LiftE s)
    LabeledRowCon x   -> Case1 $ Case3 x
    UserADTType s d p -> Case1 $ Case4 (LiftE s `PairE` d `PairE` p)
  {-# INLINE fromE #-}

  toE = \case
    Case0 case0 -> case case0 of
      Case0 UnitE -> Nat
      Case1 n     -> Fin n
      Case2 UnitE -> EffectRowKind
      Case3 UnitE -> LabeledRowKindTC
      Case4 UnitE -> LabelType
      _ -> error "impossible"
    Case1 case1 -> case case1 of
      Case0 xs                            -> RecordTyCon   xs
      Case1 (ExtLabeledItemsE xs)         -> VariantTyCon  xs
      Case2 (LiftE s)                     -> LabelCon      s
      Case3 x                             -> LabeledRowCon x
      Case4 (LiftE s `PairE` d `PairE` p) -> UserADTType s d p
      _ -> error "impossible"
    _ -> error "impossible"
  {-# INLINE toE #-}

instance SinkableE      NewtypeTyCon
instance HoistableE     NewtypeTyCon
instance AlphaEqE       NewtypeTyCon
instance AlphaHashableE NewtypeTyCon
instance RenameE        NewtypeTyCon

instance IRRep r => GenericE (BaseMonoid r) where
  type RepE (BaseMonoid r) = PairE (Atom r) (LamExpr r)
  fromE (BaseMonoid x f) = PairE x f
  {-# INLINE fromE #-}
  toE   (PairE x f) = BaseMonoid x f
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (BaseMonoid r)
instance IRRep r => HoistableE     (BaseMonoid r)
instance IRRep r => RenameE        (BaseMonoid r)
instance IRRep r => AlphaEqE       (BaseMonoid r)
instance IRRep r => AlphaHashableE (BaseMonoid r)

instance GenericE UserEffectOp where
  type RepE UserEffectOp = EitherE3
 {- Handle -}  (HandlerName `PairE` ListE CAtom `PairE` CBlock)
 {- Resume -}  (CAtom `PairE` CAtom)
 {- Perform -} (CAtom `PairE` LiftE Int)
  fromE = \case
    Handle name args body -> Case0 $ name `PairE` ListE args `PairE` body
    Resume x y            -> Case1 $ x `PairE` y
    Perform x i           -> Case2 $ x `PairE` LiftE i
  {-# INLINE fromE #-}
  toE = \case
    Case0 (name `PairE` ListE args `PairE` body) -> Handle name args body
    Case1 (x `PairE` y)                          -> Resume x y
    Case2 (x `PairE` LiftE i)                    -> Perform x i
    _ -> error "impossible"
  {-# INLINE toE #-}


instance SinkableE      UserEffectOp
instance HoistableE     UserEffectOp
instance RenameE        UserEffectOp
instance AlphaEqE       UserEffectOp
instance AlphaHashableE UserEffectOp

instance IRRep r => GenericE (DAMOp r) where
  type RepE (DAMOp r) = EitherE5
  {- Seq -}            (LiftE Direction `PairE` IxDict r `PairE` Atom r `PairE` LamExpr r)
  {- RememberDest -}   (Atom r `PairE` LamExpr r)
  {- AllocDest -}      (Atom r)
  {- Place -}          (Atom r `PairE` Atom r)
  {- Freeze -}         (Atom r)
  fromE = \case
    Seq d x y z      -> Case0 $ LiftE d `PairE` x `PairE` y `PairE` z
    RememberDest x y -> Case1 (x `PairE` y)
    AllocDest x      -> Case2 x
    Place x y        -> Case3 (x `PairE` y)
    Freeze x         -> Case4 x
  {-# INLINE fromE #-}
  toE = \case
    Case0 (LiftE d `PairE` x `PairE` y `PairE` z) -> Seq d x y z
    Case1 (x `PairE` y)                           -> RememberDest x y
    Case2 x                                       -> AllocDest x
    Case3 (x `PairE` y)                           -> Place x y
    Case4 x                                       -> Freeze x
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (DAMOp r)
instance IRRep r => HoistableE     (DAMOp r)
instance IRRep r => RenameE        (DAMOp r)
instance IRRep r => AlphaEqE       (DAMOp r)
instance IRRep r => AlphaHashableE (DAMOp r)

instance IRRep r => GenericE (Hof r) where
  type RepE (Hof r) = EitherE2
    (EitherE6
  {- For -}       (LiftE ForAnn `PairE` IxDict r `PairE` LamExpr r)
  {- While -}     (Block r)
  {- RunReader -} (Atom r `PairE` LamExpr r)
  {- RunWriter -} (MaybeE (Atom r) `PairE` BaseMonoid r `PairE` LamExpr r)
  {- RunState -}  (MaybeE (Atom r) `PairE` Atom r `PairE` LamExpr r)
  {- RunIO -}     (Block r)
    ) (EitherE4
  {- RunInit -}        (Block r)
  {- CatchException -} (WhenCore r (Block r))
  {- Linearize -}      (WhenCore r (LamExpr r `PairE` Atom r))
  {- Transpose -}      (WhenCore r (LamExpr r `PairE` Atom r)))

  fromE = \case
    For ann d body      -> Case0 (Case0 (LiftE ann `PairE` d `PairE` body))
    While body          -> Case0 (Case1 body)
    RunReader x body    -> Case0 (Case2 (x `PairE` body))
    RunWriter d bm body -> Case0 (Case3 (toMaybeE d `PairE` bm `PairE` body))
    RunState  d x body  -> Case0 (Case4 (toMaybeE d `PairE` x `PairE` body))
    RunIO body          -> Case0 (Case5 body)
    RunInit body        -> Case1 (Case0 body)
    CatchException body -> Case1 (Case1 (WhenIRE body))
    Linearize body x    -> Case1 (Case2 (WhenIRE (PairE body x)))
    Transpose body x    -> Case1 (Case3 (WhenIRE (PairE body x)))
  {-# INLINE fromE #-}
  toE = \case
    Case0 hof -> case hof of
      Case0 (LiftE ann `PairE` d `PairE` body) -> For ann d body
      Case1 body                        -> While body
      Case2 (x `PairE` body)            -> RunReader x body
      Case3 (d `PairE` bm `PairE` body) -> RunWriter (fromMaybeE d) bm body
      Case4 (d `PairE` x `PairE` body)  -> RunState  (fromMaybeE d) x body
      Case5 body                        -> RunIO     body
      _ -> error "impossible"
    Case1 hof -> case hof of
      Case0 body -> RunInit body
      Case1 (WhenIRE body) -> CatchException body
      Case2 (WhenIRE (PairE body x)) -> Linearize body x
      Case3 (WhenIRE (PairE body x)) -> Transpose body x
      _ -> error "impossible"
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE (Hof r)
instance IRRep r => HoistableE  (Hof r)
instance IRRep r => RenameE     (Hof r)
instance IRRep r => AlphaEqE (Hof r)
instance IRRep r => AlphaHashableE (Hof r)

instance IRRep r => GenericE (RefOp r) where
  type RepE (RefOp r) =
    EitherE6
      UnitE                         -- MAsk
      (BaseMonoid r `PairE` Atom r) -- MExtend
      UnitE                         -- MGet
      (Atom r)                      -- MPut
      (Atom r)                      -- IndexRef
      (LiftE Int)                   -- ProjRef
  fromE = \case
    MAsk         -> Case0 UnitE
    MExtend bm x -> Case1 (bm `PairE` x)
    MGet         -> Case2 UnitE
    MPut x       -> Case3 x
    IndexRef x   -> Case4 x
    ProjRef i    -> Case5 (LiftE i)
  {-# INLINE fromE #-}
  toE = \case
    Case0 UnitE          -> MAsk
    Case1 (bm `PairE` x) -> MExtend bm x
    Case2 UnitE          -> MGet
    Case3 x              -> MPut x
    Case4 x              -> IndexRef x
    Case5 (LiftE i)      -> ProjRef i
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (RefOp r)
instance IRRep r => HoistableE     (RefOp r)
instance IRRep r => RenameE        (RefOp r)
instance IRRep r => AlphaEqE       (RefOp r)
instance IRRep r => AlphaHashableE (RefOp r)

instance GenericE FieldRowElem where
  type RepE FieldRowElem =
    EitherE3 (ExtLabeledItemsE CType UnitE) (AtomName CoreIR `PairE` CType) (AtomName CoreIR)
  fromE = \case
    StaticFields items         -> Case0 $ ExtLabeledItemsE $ NoExt items
    DynField  labVarName labTy -> Case1 $ labVarName `PairE` labTy
    DynFields fieldVarName     -> Case2 $ fieldVarName
  {-# INLINE fromE #-}
  toE = \case
    Case0 (ExtLabeledItemsE (Ext items _)) -> StaticFields items
    Case1 (n `PairE` t) -> DynField n t
    Case2 n             -> DynFields n
    _ -> error "unreachable"
  {-# INLINE toE #-}
instance SinkableE      FieldRowElem
instance HoistableE     FieldRowElem
instance RenameE        FieldRowElem
instance AlphaEqE       FieldRowElem
instance AlphaHashableE FieldRowElem

instance GenericE FieldRowElems where
  type RepE FieldRowElems = ListE FieldRowElem
  fromE = ListE . fromFieldRowElems
  {-# INLINE fromE #-}
  toE = fieldRowElemsFromList . fromListE
  {-# INLINE toE #-}
instance SinkableE      FieldRowElems
instance HoistableE     FieldRowElems
instance RenameE        FieldRowElems
instance AlphaEqE       FieldRowElems
instance AlphaHashableE FieldRowElems

newtype ExtLabeledItemsE (e1::E) (e2::E) (n::S) =
  ExtLabeledItemsE
   { fromExtLabeledItemsE :: ExtLabeledItems (e1 n) (e2 n) }
   deriving (Show, Generic)
instance (Store (e1 n), Store (e2 n)) => Store (ExtLabeledItemsE e1 e2 n)

instance GenericE SimpInCore where
  type RepE SimpInCore = EitherE4
   {- LiftSimp -} (MaybeE CType `PairE` SAtom)
   {- LiftSimpFun -} (PiType `PairE` LamExpr SimpIR)
   {- TabLam -}   (TabPiType CoreIR `PairE` TabLamExpr)
   {- ACase -}    (SAtom `PairE` ListE (Abs SBinder CAtom) `PairE` CType)
  fromE = \case
    LiftSimp ty x             -> Case0 $ toMaybeE ty `PairE` x
    LiftSimpFun ty x          -> Case1 $ ty `PairE` x
    TabLam ty lam             -> Case2 $ ty `PairE` lam
    ACase scrut alts resultTy -> Case3 $ scrut `PairE` ListE alts `PairE` resultTy
  {-# INLINE fromE #-}

  toE = \case
    Case0 (ty `PairE` x)                    -> LiftSimp (fromMaybeE ty) x
    Case1 (ty `PairE` x)                    -> LiftSimpFun ty x
    Case2 (ty `PairE` lam)                  -> TabLam ty lam
    Case3 (x `PairE` ListE alts `PairE` ty) -> ACase x alts ty
    _ -> error "impossible"
  {-# INLINE toE #-}

instance SinkableE      SimpInCore
instance HoistableE     SimpInCore
instance RenameE        SimpInCore
instance AlphaEqE       SimpInCore
instance AlphaHashableE SimpInCore

instance IRRep r => GenericE (Atom r) where
  -- As tempting as it might be to reorder cases here, the current permutation
  -- was chosen as to make GHC inliner confident enough to simplify through
  -- toE/fromE entirely. If you wish to modify the order, please consult the
  -- GHC Core dump to make sure you haven't regressed this optimization.
  type RepE (Atom r) = EitherE5
              (EitherE2
                   -- We isolate those few cases (and reorder them
                   -- compared to the data definition) because they need special
                   -- handling when you substitute with atoms. The rest just act
                   -- like containers
  {- Var -}        (AtomName r)
  {- ProjectElt -} ( LiftE Projection `PairE` Atom r)
            ) (EitherE3
  {- Lam -}        (WhenCore r (LamExpr r `PairE` LiftE Arrow `PairE` EffAbs))
  {- Pi -}         (WhenCore r PiType)
  {- TabPi -}      (TabPiType r)
            ) (EitherE4
  {- DepPairTy -}  (DepPairType r)
  {- DepPair -}    ( Atom r `PairE` Atom r `PairE` DepPairType r)
  {- DictCon  -}   (WhenCore r DictExpr)
  {- DictTy  -}    (WhenCore r DictType)
            ) (EitherE2
  {- NewtypeCon -}     (WhenCore r (NewtypeCon `PairE` Atom r))
  {- NewtypeTyCon -}   (WhenCore r NewtypeTyCon)
            ) (EitherE6
  {- Con -}        (ComposeE (PrimCon r) (Atom r))
  {- TC -}         (ComposeE (PrimTC  r) (Atom r))
  {- Eff -}        ( WhenCore r (EffectRow r))
  {- PtrVar -}     PtrName
  {- RepValAtom -} ( WhenSimp r (RepVal r))
  {- SimpInCore -} ( WhenCore r SimpInCore)
              )
  fromE atom = case atom of
    Var v -> Case0 (Case0 v)
    ProjectElt idxs x -> Case0 (Case1 (PairE (LiftE idxs) x))
    Lam lamExpr arr eff -> Case1 (Case0 (WhenIRE (lamExpr `PairE` LiftE arr `PairE` eff)))
    Pi  piExpr  -> Case1 (Case1 (WhenIRE piExpr))
    TabPi  piExpr  -> Case1 (Case2 piExpr)
    DepPairTy ty -> Case2 (Case0 ty)
    DepPair l r ty -> Case2 (Case1 $ l `PairE` r `PairE` ty)
    DictCon d      -> Case2 $ Case2 $ WhenIRE d
    DictTy  d      -> Case2 $ Case3 $ WhenIRE d
    NewtypeCon c x -> Case3 $ Case0 $ WhenIRE (c `PairE` x)
    NewtypeTyCon t -> Case3 $ Case1 $ WhenIRE t
    Con con -> Case4 $ Case0 $ ComposeE con
    TC  con -> Case4 $ Case1 $ ComposeE con
    Eff effs -> Case4 $ Case2 $ WhenIRE effs
    PtrVar v -> Case4 $ Case3 $ v
    RepValAtom rv -> Case4 $ Case4 $ WhenIRE $ rv
    SimpInCore x  -> Case4 $ Case5 $ WhenIRE x
  {-# INLINE fromE #-}

  toE atom = case atom of
    Case0 val -> case val of
      Case0 v -> Var v
      Case1 (PairE (LiftE idxs) x) -> ProjectElt idxs x
      _ -> error "impossible"
    Case1 val -> case val of
      Case0 (WhenIRE (lamExpr `PairE` LiftE arr `PairE` effs)) -> Lam lamExpr arr effs
      Case1 (WhenIRE piExpr)  -> Pi  piExpr
      Case2 piExpr  -> TabPi  piExpr
      _ -> error "impossible"
    Case2 val -> case val of
      Case0 ty      -> DepPairTy ty
      Case1 (l `PairE` r `PairE` ty) -> DepPair l r ty
      Case2 (WhenIRE d) -> DictCon d
      Case3 (WhenIRE d) -> DictTy  d
      _ -> error "impossible"
    Case3 val -> case val of
      Case0 (WhenIRE (c `PairE` x)) -> NewtypeCon c x
      Case1 (WhenIRE t)             -> NewtypeTyCon t
      _ -> error "impossible"
    Case4 val -> case val of
      Case0 (ComposeE con) -> Con con
      Case1 (ComposeE con) -> TC con
      Case2 (WhenIRE effs) -> Eff effs
      Case3 v -> PtrVar v
      Case4 (WhenIRE rv) -> RepValAtom rv
      Case5 (WhenIRE x)  -> SimpInCore x
      _ -> error "impossible"
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (Atom r)
instance IRRep r => HoistableE     (Atom r)
instance IRRep r => AlphaEqE       (Atom r)
instance IRRep r => AlphaHashableE (Atom r)
instance IRRep r => RenameE        (Atom r)

instance IRRep r => GenericE (Expr r) where
  type RepE (Expr r) = EitherE2
    ( EitherE6
 {- App -}    (WhenCore r (Atom r `PairE` Atom r `PairE` ListE (Atom r)))
 {- TabApp -} (Atom r `PairE` Atom r `PairE` ListE (Atom r))
 {- Case -}   (Atom r `PairE` ListE (Alt r) `PairE` Type r `PairE` EffectRow r)
 {- Atom -}   (Atom r)
 {- Hof -}    (Hof r)
 {- TopApp -} (WhenSimp r (TopFunName `PairE` ListE (Atom r)))
    )
    ( EitherE7
 {- TabCon -}          (Type r `PairE` ListE (Atom r))
 {- RefOp -}           (Atom r `PairE` RefOp r)
 {- PrimOp -}          (ComposeE PrimOp (Atom r))
 {- UserEffectOp -}    (WhenCore r UserEffectOp)
 {- ProjMethod -}      (WhenCore r (Atom r `PairE` LiftE Int))
 {- RecordVariantOp -} (WhenCore r (ComposeE RecordVariantOp (Atom r)))
 {- DAMOp -}           (WhenSimp r (DAMOp r)))

  fromE = \case
    App    f (x:|xs)   -> Case0 $ Case0 (WhenIRE (f `PairE` x `PairE` ListE xs))
    TabApp f (x:|xs)   -> Case0 $ Case1 (f `PairE` x `PairE` ListE xs)
    Case e alts ty eff -> Case0 $ Case2 (e `PairE` ListE alts `PairE` ty `PairE` eff)
    Atom x             -> Case0 $ Case3 (x)
    Hof hof            -> Case0 $ Case4 hof
    TopApp f xs        -> Case0 $ Case5 (WhenIRE (f `PairE` ListE xs))
    TabCon ty xs       -> Case1 $ Case0 (ty `PairE` ListE xs)
    RefOp ref op       -> Case1 $ Case1 (ref `PairE` op)
    PrimOp op          -> Case1 $ Case2 (ComposeE op)
    UserEffectOp op    -> Case1 $ Case3 (WhenIRE op)
    ProjMethod d i     -> Case1 $ Case4 (WhenIRE (d `PairE` LiftE i))
    RecordVariantOp op -> Case1 $ Case5 (WhenIRE (ComposeE op))
    DAMOp op           -> Case1 $ Case6 (WhenIRE op)
  {-# INLINE fromE #-}
  toE = \case
    Case0 case0 -> case case0 of
      Case0 (WhenIRE (f `PairE` x `PairE` ListE xs))        -> App    f (x:|xs)
      Case1 (f `PairE` x `PairE` ListE xs)                -> TabApp f (x:|xs)
      Case2 (e `PairE` ListE alts `PairE` ty `PairE` eff) -> Case e alts ty eff
      Case3 (x)                                           -> Atom x
      Case4 hof                                           -> Hof hof
      Case5 (WhenIRE (f `PairE` ListE xs))                -> TopApp f xs
      _ -> error "impossible"
    Case1 case1 -> case case1 of
      Case0 (ty `PairE` ListE xs) -> TabCon ty xs
      Case1 (ref `PairE` op)      -> RefOp ref op
      Case2 (ComposeE op)         -> PrimOp op
      Case3 (WhenIRE op)            -> UserEffectOp op
      Case4 (WhenIRE (d `PairE` LiftE i)) -> ProjMethod d i
      Case5 (WhenIRE (ComposeE op)) -> RecordVariantOp op
      Case6 (WhenIRE op)            -> DAMOp op
      _ -> error "impossible"
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (Expr r)
instance IRRep r => HoistableE     (Expr r)
instance IRRep r => AlphaEqE       (Expr r)
instance IRRep r => AlphaHashableE (Expr r)
instance IRRep r => RenameE        (Expr r)

instance GenericE (ExtLabeledItemsE e1 e2) where
  type RepE (ExtLabeledItemsE e1 e2) = EitherE (ComposeE LabeledItems e1)
                                               (ComposeE LabeledItems e1 `PairE` e2)
  fromE (ExtLabeledItemsE (Ext items Nothing))  = LeftE  (ComposeE items)
  fromE (ExtLabeledItemsE (Ext items (Just t))) = RightE (ComposeE items `PairE` t)
  {-# INLINE fromE #-}
  toE (LeftE  (ComposeE items          )) = ExtLabeledItemsE (Ext items Nothing)
  toE (RightE (ComposeE items `PairE` t)) = ExtLabeledItemsE (Ext items (Just t))
  {-# INLINE toE #-}

instance (SinkableE e1, SinkableE e2) => SinkableE (ExtLabeledItemsE e1 e2)
instance (HoistableE  e1, HoistableE  e2) => HoistableE  (ExtLabeledItemsE e1 e2)
instance (AlphaEqE    e1, AlphaEqE    e2) => AlphaEqE    (ExtLabeledItemsE e1 e2)
instance (AlphaHashableE    e1, AlphaHashableE    e2) => AlphaHashableE    (ExtLabeledItemsE e1 e2)
instance (RenameE     e1, RenameE     e2) => RenameE     (ExtLabeledItemsE e1 e2)

instance IRRep r => GenericE (Block r) where
  type RepE (Block r) = PairE (MaybeE (PairE (Type r) (EffectRow r))) (Abs (Nest (Decl r)) (Atom r))
  fromE (Block (BlockAnn ty effs) decls result) = PairE (JustE (PairE ty effs)) (Abs decls result)
  fromE (Block NoBlockAnn Empty result) = PairE NothingE (Abs Empty result)
  fromE _ = error "impossible"
  {-# INLINE fromE #-}
  toE   (PairE (JustE (PairE ty effs)) (Abs decls result)) = Block (BlockAnn ty effs) decls result
  toE   (PairE NothingE (Abs Empty result)) = Block NoBlockAnn Empty result
  toE   _ = error "impossible"
  {-# INLINE toE #-}

deriving instance IRRep r => Show (BlockAnn r n l)

instance IRRep r => SinkableE      (Block r)
instance IRRep r => HoistableE     (Block r)
instance IRRep r => AlphaEqE       (Block r)
instance IRRep r => AlphaHashableE (Block r)
instance IRRep r => RenameE        (Block r)
deriving instance IRRep r => Show (Block r n)
deriving via WrapE (Block r) n instance IRRep r => Generic (Block r n)

instance IRRep r => GenericB (NonDepNest r ann) where
  type RepB (NonDepNest r ann) = (LiftB (ListE ann)) `PairB` Nest (AtomNameBinder r)
  fromB (NonDepNest bs anns) = LiftB (ListE anns) `PairB` bs
  {-# INLINE fromB #-}
  toB (LiftB (ListE anns) `PairB` bs) = NonDepNest bs anns
  {-# INLINE toB #-}
instance IRRep r => ProvesExt (NonDepNest r ann)
instance IRRep r => BindsNames (NonDepNest r ann)
instance (IRRep r, SinkableE  ann) => SinkableB  (NonDepNest r ann)
instance (IRRep r, HoistableE ann) => HoistableB (NonDepNest r ann)
instance (IRRep r, RenameE ann, SinkableE ann) => RenameB (NonDepNest r ann)
instance (IRRep r, AlphaEqE       ann) => AlphaEqB       (NonDepNest r ann)
instance (IRRep r, AlphaHashableE ann) => AlphaHashableB (NonDepNest r ann)
deriving instance (Show (ann n)) => IRRep r => Show (NonDepNest r ann n l)

instance GenericB SuperclassBinders where
  type RepB SuperclassBinders = PairB (LiftB (ListE CType)) (Nest (AtomNameBinder CoreIR))
  fromB (SuperclassBinders bs tys) = PairB (LiftB (ListE tys)) bs
  toB   (PairB (LiftB (ListE tys)) bs) = SuperclassBinders bs tys

instance BindsNameList SuperclassBinders (AtomNameC CoreIR) where
  bindNameList (SuperclassBinders bs _) xs = bindNameList bs xs

instance ProvesExt   SuperclassBinders
instance BindsNames  SuperclassBinders
instance SinkableB   SuperclassBinders
instance HoistableB  SuperclassBinders
instance RenameB     SuperclassBinders
instance AlphaEqB SuperclassBinders
instance AlphaHashableB SuperclassBinders

instance GenericE ClassDef where
  type RepE ClassDef =
    LiftE (SourceName, [SourceName])
     `PairE` Abs (Nest RolePiBinder) (Abs SuperclassBinders (ListE MethodType))
  fromE (ClassDef name names b scs tys) =
    LiftE (name, names) `PairE` Abs b (Abs scs (ListE tys))
  {-# INLINE fromE #-}
  toE (LiftE (name, names) `PairE` Abs b (Abs scs (ListE tys))) =
    ClassDef name names b scs tys
  {-# INLINE toE #-}

instance SinkableE ClassDef
instance HoistableE  ClassDef
instance AlphaEqE ClassDef
instance AlphaHashableE ClassDef
instance RenameE     ClassDef
deriving instance Show (ClassDef n)
deriving via WrapE ClassDef n instance Generic (ClassDef n)

instance GenericE InstanceDef where
  type RepE InstanceDef =
    ClassName `PairE` Abs (Nest RolePiBinder) (ListE CType `PairE` InstanceBody)
  fromE (InstanceDef name bs params body) =
    name `PairE` Abs bs (ListE params `PairE` body)
  toE (name `PairE` Abs bs (ListE params `PairE` body)) =
    InstanceDef name bs params body

instance SinkableE InstanceDef
instance HoistableE  InstanceDef
instance AlphaEqE InstanceDef
instance AlphaHashableE InstanceDef
instance RenameE     InstanceDef
deriving instance Show (InstanceDef n)
deriving via WrapE InstanceDef n instance Generic (InstanceDef n)

instance GenericE InstanceBody where
  type RepE InstanceBody = ListE CAtom `PairE` ListE (Block CoreIR)
  fromE (InstanceBody scs methods) = ListE scs `PairE` ListE methods
  toE   (ListE scs `PairE` ListE methods) = InstanceBody scs methods

instance SinkableE InstanceBody
instance HoistableE  InstanceBody
instance AlphaEqE InstanceBody
instance AlphaHashableE InstanceBody
instance RenameE     InstanceBody

instance GenericE MethodType where
  type RepE MethodType = PairE (LiftE [Bool]) CType
  fromE (MethodType explicit ty) = PairE (LiftE explicit) ty
  toE   (PairE (LiftE explicit) ty) = MethodType explicit ty

instance SinkableE      MethodType
instance HoistableE     MethodType
instance AlphaEqE       MethodType
instance AlphaHashableE MethodType
instance RenameE     MethodType

instance GenericE DictType where
  type RepE DictType = LiftE SourceName `PairE` ClassName `PairE` ListE CType
  fromE (DictType sourceName className params) =
    LiftE sourceName `PairE` className `PairE` ListE params
  toE (LiftE sourceName `PairE` className `PairE` ListE params) =
    DictType sourceName className params

instance SinkableE      DictType
instance HoistableE     DictType
instance AlphaEqE       DictType
instance AlphaHashableE DictType
instance RenameE        DictType

instance GenericE DictExpr where
  type RepE DictExpr =
    EitherE4
 {- InstanceDict -}      (PairE InstanceName (ListE CAtom))
 {- InstantiatedGiven -} (PairE CAtom (ListE CAtom))
 {- SuperclassProj -}    (PairE CAtom (LiftE Int))
 {- IxFin -}             CAtom
  fromE d = case d of
    InstanceDict v args -> Case0 $ PairE v (ListE args)
    InstantiatedGiven given (arg:|args) -> Case1 $ PairE given (ListE (arg:args))
    SuperclassProj x i -> Case2 (PairE x (LiftE i))
    IxFin x            -> Case3 x
  toE d = case d of
    Case0 (PairE v (ListE args)) -> InstanceDict v args
    Case1 (PairE given (ListE ~(arg:args))) -> InstantiatedGiven given (arg:|args)
    Case2 (PairE x (LiftE i)) -> SuperclassProj x i
    Case3 x -> IxFin x
    _ -> error "impossible"

instance SinkableE      DictExpr
instance HoistableE     DictExpr
instance AlphaEqE       DictExpr
instance AlphaHashableE DictExpr
instance RenameE        DictExpr

instance GenericE Cache where
  type RepE Cache =
            EMap SpecializationSpec TopFunName
    `PairE` EMap AbsDict SpecDictName
    `PairE` EMap LinearizationSpec (PairE TopFunName TopFunName)
    `PairE` LiftE (M.Map ModuleSourceName (FileHash, [ModuleSourceName]))
    `PairE` ListE (        LiftE ModuleSourceName
                   `PairE` LiftE FileHash
                   `PairE` ListE ModuleName
                   `PairE` ModuleName)
  fromE (Cache x y z parseCache evalCache) =
    x `PairE` y `PairE` z `PairE` LiftE parseCache `PairE`
      ListE [LiftE sourceName `PairE` LiftE hashVal `PairE` ListE deps `PairE` result
             | (sourceName, ((hashVal, deps), result)) <- M.toList evalCache ]
  {-# INLINE fromE #-}
  toE   (x `PairE` y `PairE` z `PairE` LiftE parseCache `PairE` ListE evalCache) =
    Cache x y z parseCache
      (M.fromList
       [(sourceName, ((hashVal, deps), result))
       | LiftE sourceName `PairE` LiftE hashVal `PairE` ListE deps `PairE` result
          <- evalCache])
  {-# INLINE toE #-}

instance SinkableE  Cache
instance HoistableE Cache
instance AlphaEqE   Cache
instance RenameE     Cache
instance Store (Cache n)

instance Monoid (Cache n) where
  mempty = Cache mempty mempty mempty mempty mempty
  mappend = (<>)

instance Semigroup (Cache n) where
  -- right-biased instead of left-biased
  Cache x1 x2 x3 x4 x5 <> Cache y1 y2 y3 y4 y5 =
    Cache (y1<>x1) (y2<>x2) (y3<>x3) (y4<>x4) (x5<>y5)

instance GenericE LamBinding where
  type RepE LamBinding = PairE (LiftE Arrow) CType
  fromE (LamBinding arr ty) = PairE (LiftE arr) ty
  {-# INLINE fromE #-}
  toE   (PairE (LiftE arr) ty) = LamBinding arr ty
  {-# INLINE toE #-}

instance SinkableE     LamBinding
instance HoistableE    LamBinding
instance RenameE       LamBinding
instance AlphaEqE       LamBinding
instance AlphaHashableE LamBinding

instance GenericE (LamExpr r) where
  type RepE (LamExpr r) = Abs (Nest (Binder r)) (Block r)
  fromE (LamExpr b block) = Abs b block
  {-# INLINE fromE #-}
  toE   (Abs b block) = LamExpr b block
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (LamExpr r)
instance IRRep r => HoistableE     (LamExpr r)
instance IRRep r => AlphaEqE       (LamExpr r)
instance IRRep r => AlphaHashableE (LamExpr r)
instance IRRep r => RenameE        (LamExpr r)
deriving instance IRRep r => Show (LamExpr r n)
deriving via WrapE (LamExpr r) n instance IRRep r => Generic (LamExpr r n)

instance GenericE (DestBlock r) where
  type RepE (DestBlock r) = Abs (Binder r) (Block r)
  fromE (DestBlock b block) = Abs b block
  {-# INLINE fromE #-}
  toE   (Abs b block) = DestBlock b block
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (DestBlock r)
instance IRRep r => HoistableE     (DestBlock r)
instance IRRep r => AlphaEqE       (DestBlock r)
instance IRRep r => AlphaHashableE (DestBlock r)
instance IRRep r => RenameE        (DestBlock r)
deriving instance IRRep r => Show (DestBlock r n)
deriving via WrapE (DestBlock r) n instance IRRep r => Generic (DestBlock r n)

instance GenericE (DestLamExpr r) where
  type RepE (DestLamExpr r) = Abs (Nest (Binder r)) (DestBlock r)
  fromE (DestLamExpr b block) = Abs b block
  {-# INLINE fromE #-}
  toE   (Abs b block) = DestLamExpr b block
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (DestLamExpr r)
instance IRRep r => HoistableE     (DestLamExpr r)
instance IRRep r => AlphaEqE       (DestLamExpr r)
instance IRRep r => AlphaHashableE (DestLamExpr r)
instance IRRep r => RenameE        (DestLamExpr r)
deriving instance IRRep r => Show (DestLamExpr r n)
deriving via WrapE (DestLamExpr r) n instance IRRep r => Generic (DestLamExpr r n)

instance GenericE PiBinding where
  type RepE PiBinding = PairE (LiftE Arrow) CType
  fromE (PiBinding arr ty) = PairE (LiftE arr) ty
  {-# INLINE fromE #-}
  toE   (PairE (LiftE arr) ty) = PiBinding arr ty
  {-# INLINE toE #-}

instance SinkableE      PiBinding
instance HoistableE     PiBinding
instance RenameE        PiBinding
instance AlphaEqE       PiBinding
instance AlphaHashableE PiBinding

instance GenericB PiBinder where
  type RepB PiBinder = BinderP (AtomNameC CoreIR) PiBinding
  fromB (PiBinder b ty arr) = b :> PiBinding arr ty
  toB   (b :> PiBinding arr ty) = PiBinder b ty arr

instance BindsAtMostOneName PiBinder (AtomNameC CoreIR) where
  PiBinder b _ _ @> x = b @> x
  {-# INLINE (@>) #-}

instance BindsOneName PiBinder (AtomNameC CoreIR) where
  binderName (PiBinder b _ _) = binderName b
  {-# INLINE binderName #-}

instance HasNameHint (PiBinder n l) where
  getNameHint (PiBinder b _ _) = getNameHint b
  {-# INLINE getNameHint #-}

instance ProvesExt   PiBinder
instance BindsNames  PiBinder
instance SinkableB   PiBinder
instance HoistableB  PiBinder
instance RenameB     PiBinder
instance AlphaEqB PiBinder
instance AlphaHashableB PiBinder

instance GenericE PiType where
  type RepE PiType = Abs PiBinder (PairE (EffectRow CoreIR) CType)
  fromE (PiType b eff resultTy) = Abs b (PairE eff resultTy)
  {-# INLINE fromE #-}
  toE   (Abs b (PairE eff resultTy)) = PiType b eff resultTy
  {-# INLINE toE #-}

instance SinkableE      PiType
instance HoistableE     PiType
instance AlphaEqE       PiType
instance AlphaHashableE PiType
instance RenameE        PiType
deriving instance Show (PiType n)
deriving via WrapE PiType n instance Generic (PiType n)

instance GenericB RolePiBinder where
  type RepB RolePiBinder =
    PairB (LiftB (LiftE ParamRole))
          (BinderP (AtomNameC CoreIR) PiBinding)
  fromB (RolePiBinder b ty arr role) = PairB (LiftB (LiftE role)) (b :> PiBinding arr ty)
  {-# INLINE fromB #-}
  toB   (PairB (LiftB (LiftE role)) (b :> PiBinding arr ty)) = RolePiBinder b ty arr role
  {-# INLINE toB #-}

instance HasNameHint (RolePiBinder n l) where
  getNameHint (RolePiBinder b _ _ _) = getNameHint b
  {-# INLINE getNameHint #-}

instance BindsAtMostOneName RolePiBinder (AtomNameC CoreIR) where
  RolePiBinder b _ _ _ @> x = b @> x

instance BindsOneName RolePiBinder (AtomNameC CoreIR) where
  binderName (RolePiBinder b _ _ _) = binderName b

instance ProvesExt   RolePiBinder
instance BindsNames  RolePiBinder
instance SinkableB   RolePiBinder
instance HoistableB  RolePiBinder
instance RenameB     RolePiBinder
instance AlphaEqB       RolePiBinder
instance AlphaHashableB RolePiBinder

instance IRRep r => GenericE (IxDict r) where
  type RepE (IxDict r) =
    EitherE3
      (WhenCore r (Atom r))
      (Atom r)
      (Type r `PairE` SpecDictName `PairE` ListE (Atom r))
  fromE = \case
    IxDictAtom x -> Case0 $ WhenIRE x
    IxDictRawFin n -> Case1 $ n
    IxDictSpecialized t d xs -> Case2 $ t `PairE` d `PairE` ListE xs
  {-# INLINE fromE #-}
  toE = \case
    Case0 (WhenIRE x)          -> IxDictAtom x
    Case1 (n)                  -> IxDictRawFin n
    Case2 (t `PairE` d `PairE` ListE xs) -> IxDictSpecialized t d xs
    _ -> error "impossible"
  {-# INLINE toE #-}

instance IRRep r => SinkableE   (IxDict r)
instance IRRep r => HoistableE  (IxDict r)
instance IRRep r => RenameE     (IxDict r)
instance IRRep r => AlphaEqE       (IxDict r)
instance IRRep r => AlphaHashableE (IxDict r)

instance IRRep r => GenericE (IxType r) where
  type RepE (IxType r) = PairE (Type r) (IxDict r)
  fromE (IxType ty d) = PairE ty d
  {-# INLINE fromE #-}
  toE   (PairE ty d) = IxType ty d
  {-# INLINE toE #-}

instance IRRep r => SinkableE   (IxType r)
instance IRRep r => HoistableE  (IxType r)
instance IRRep r => RenameE     (IxType r)

instance IRRep r => AlphaEqE (IxType r) where
  alphaEqE (IxType t1 _) (IxType t2 _) = alphaEqE t1 t2

instance IRRep r => AlphaHashableE (IxType r) where
  hashWithSaltE env salt (IxType t _) = hashWithSaltE env salt t

instance IRRep r => GenericE (TabPiType r) where
  type RepE (TabPiType r) = Abs (IxBinder r) (Type r)
  fromE (TabPiType b resultTy) = Abs b resultTy
  {-# INLINE fromE #-}
  toE   (Abs b resultTy) = TabPiType b resultTy
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (TabPiType r)
instance IRRep r => HoistableE     (TabPiType r)
instance IRRep r => AlphaEqE       (TabPiType r)
instance IRRep r => AlphaHashableE (TabPiType r)
instance IRRep r => RenameE        (TabPiType r)
deriving instance IRRep r => Show (TabPiType r n)
deriving via WrapE (TabPiType r) n instance IRRep r => Generic (TabPiType r n)

instance GenericE (NaryPiType r) where
  type RepE (NaryPiType r) = Abs (Nest (Binder r)) (PairE (EffectRow r) (Type r))
  fromE (NaryPiType bs eff resultTy) = Abs bs (PairE eff resultTy)
  {-# INLINE fromE #-}
  toE   (Abs bs (PairE eff resultTy)) = NaryPiType bs eff resultTy
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (NaryPiType r)
instance IRRep r => HoistableE     (NaryPiType r)
instance IRRep r => AlphaEqE       (NaryPiType r)
instance IRRep r => AlphaHashableE (NaryPiType r)
instance IRRep r => RenameE     (NaryPiType r)
deriving instance IRRep r => Show (NaryPiType r n)
deriving via WrapE (NaryPiType r) n instance IRRep r => Generic (NaryPiType r n)
instance IRRep r => Store (NaryPiType r n)

instance GenericE (DepPairType r) where
  type RepE (DepPairType r) = Abs (Binder r) (Type r)
  fromE (DepPairType b resultTy) = Abs b resultTy
  {-# INLINE fromE #-}
  toE   (Abs b resultTy) = DepPairType b resultTy
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (DepPairType r)
instance IRRep r => HoistableE     (DepPairType r)
instance IRRep r => AlphaEqE       (DepPairType r)
instance IRRep r => AlphaHashableE (DepPairType r)
instance IRRep r => RenameE        (DepPairType r)
deriving instance IRRep r => Show (DepPairType r n)
deriving via WrapE (DepPairType r) n instance IRRep r => Generic (DepPairType r n)

instance GenericE SynthCandidates where
  type RepE SynthCandidates =
    ListE (AtomName CoreIR) `PairE` ListE (PairE ClassName (ListE InstanceName))
  fromE (SynthCandidates xs ys) = ListE xs `PairE` ListE ys'
    where ys' = map (\(k,vs) -> PairE k (ListE vs)) (M.toList ys)
  {-# INLINE fromE #-}
  toE (ListE xs `PairE` ListE ys) = SynthCandidates xs ys'
    where ys' = M.fromList $ map (\(PairE k (ListE vs)) -> (k,vs)) ys
  {-# INLINE toE #-}

instance SinkableE      SynthCandidates
instance HoistableE     SynthCandidates
instance AlphaEqE       SynthCandidates
instance AlphaHashableE SynthCandidates
instance RenameE        SynthCandidates

instance IRRep r => GenericE (AtomBinding r) where
  type RepE (AtomBinding r) =
     EitherE2 (EitherE5
      (DeclBinding   r)              -- LetBound
      (WhenCore r LamBinding)        -- LamBound
      (WhenCore r PiBinding )        -- PiBound
                          (Type          r)  -- MiscBound
      (WhenCore r SolverBinding)             -- SolverBound
     ) (EitherE3
      (WhenCore r NoInlineDef)                       -- NoinlineFun
      (WhenSimp r (RepVal SimpIR))                   -- TopDataBound
      (WhenCore r (NaryPiType r `PairE` TopFunName)) -- FFIFunBound
     )

  fromE = \case
    LetBound    x -> Case0 $ Case0 x
    LamBound    x -> Case0 $ Case1 $ WhenIRE x
    PiBound     x -> Case0 $ Case2 $ WhenIRE x
    MiscBound   x -> Case0 $ Case3 x
    SolverBound x -> Case0 $ Case4 $ WhenIRE x
    NoinlineFun x -> Case1 $ Case0 $ WhenIRE x
    TopDataBound repVal -> Case1 $ Case1 $ WhenIRE repVal
    FFIFunBound ty v    -> Case1 $ Case2 $ WhenIRE $ ty `PairE` v
  {-# INLINE fromE #-}

  toE = \case
    Case0 x' -> case x' of
      Case0 x         -> LetBound x
      Case1 (WhenIRE x) -> LamBound x
      Case2 (WhenIRE x) -> PiBound  x
      Case3 x           -> MiscBound x
      Case4 (WhenIRE x) -> SolverBound x
      _ -> error "impossible"
    Case1 x' -> case x' of
      Case0 (WhenIRE x) -> NoinlineFun x
      Case1 (WhenIRE repVal)                         -> TopDataBound repVal
      Case2 (WhenIRE (ty `PairE` v))                 -> FFIFunBound ty v
      _ -> error "impossible"
    _ -> error "impossible"
  {-# INLINE toE #-}


instance IRRep r => SinkableE   (AtomBinding r)
instance IRRep r => HoistableE  (AtomBinding r)
instance IRRep r => RenameE     (AtomBinding r)
instance IRRep r => AlphaEqE       (AtomBinding r)
instance IRRep r => AlphaHashableE (AtomBinding r)

instance GenericE NoInlineDef where
  type RepE NoInlineDef = LiftE (Int, [Arrow]) `PairE` NaryPiType CoreIR `PairE` Type CoreIR `PairE` Atom CoreIR
  fromE (NoInlineDef n arr ty ty' x) = LiftE (n,arr) `PairE` ty `PairE` ty' `PairE` x
  {-# INLINE fromE #-}
  toE   (LiftE (n,arr) `PairE` ty `PairE` ty' `PairE` x) = NoInlineDef n arr ty ty' x
  {-# INLINE toE #-}

instance SinkableE      NoInlineDef
instance HoistableE     NoInlineDef
instance RenameE        NoInlineDef
instance AlphaEqE       NoInlineDef
instance AlphaHashableE NoInlineDef

instance GenericE TopFunDef where
  type RepE TopFunDef = EitherE3 SpecializationSpec LinearizationSpec LinearizationSpec
  fromE = \case
    Specialization       s -> Case0 s
    LinearizationPrimal  s -> Case1 s
    LinearizationTangent s -> Case2 s
  {-# INLINE fromE #-}
  toE = \case
    Case0 s ->   Specialization       s
    Case1 s ->   LinearizationPrimal  s
    Case2 s ->   LinearizationTangent s
    _ -> error "impossible"
  {-# INLINE toE #-}

instance SinkableE      TopFunDef
instance HoistableE     TopFunDef
instance RenameE        TopFunDef
instance AlphaEqE       TopFunDef
instance AlphaHashableE TopFunDef

instance GenericE TopFun where
  type RepE TopFun = EitherE
        (TopFunDef `PairE` NaryPiType SimpIR `PairE` LamExpr SimpIR `PairE` ComposeE EvalStatus TopFunLowerings)
        (LiftE (String, IFunType))
  fromE = \case
    DexTopFun def ty simp status -> LeftE (def `PairE` ty `PairE` simp `PairE` ComposeE status)
    FFITopFun name ty    -> RightE (LiftE (name, ty))
  {-# INLINE fromE #-}
  toE = \case
    LeftE  (def `PairE` ty `PairE` simp `PairE` ComposeE status) -> DexTopFun def ty simp status
    RightE (LiftE (name, ty))            -> FFITopFun name ty
  {-# INLINE toE #-}

instance SinkableE      TopFun
instance HoistableE     TopFun
instance RenameE        TopFun
instance AlphaEqE       TopFun
instance AlphaHashableE TopFun

instance GenericE SpecializationSpec where
  type RepE SpecializationSpec =
         PairE (AtomName CoreIR) (Abs (Nest (Binder CoreIR)) (ListE CType))
  fromE (AppSpecialization fname (Abs bs args)) = PairE fname (Abs bs args)
  {-# INLINE fromE #-}
  toE   (PairE fname (Abs bs args)) = AppSpecialization fname (Abs bs args)
  {-# INLINE toE #-}

instance HasNameHint (SpecializationSpec n) where
  getNameHint (AppSpecialization f _) = getNameHint f

instance SinkableE      SpecializationSpec
instance HoistableE     SpecializationSpec
instance RenameE        SpecializationSpec
instance AlphaEqE       SpecializationSpec
instance AlphaHashableE SpecializationSpec

instance GenericE LinearizationSpec where
  type RepE LinearizationSpec = PairE TopFunName (LiftE [Active])
  fromE (LinearizationSpec fname actives) = PairE fname (LiftE actives)
  {-# INLINE fromE #-}
  toE   (PairE fname (LiftE actives)) = LinearizationSpec fname actives
  {-# INLINE toE #-}

instance SinkableE      LinearizationSpec
instance HoistableE     LinearizationSpec
instance RenameE        LinearizationSpec
instance AlphaEqE       LinearizationSpec
instance AlphaHashableE LinearizationSpec

instance GenericE SolverBinding where
  type RepE SolverBinding = EitherE2
                                  (PairE CType (LiftE SrcPosCtx))
                                  CType
  fromE = \case
    InfVarBound  ty ctx -> Case0 (PairE ty (LiftE ctx))
    SkolemBound  ty     -> Case1 ty
  {-# INLINE fromE #-}

  toE = \case
    Case0 (PairE ty (LiftE ct)) -> InfVarBound  ty ct
    Case1 ty                    -> SkolemBound  ty
    _ -> error "impossible"
  {-# INLINE toE #-}

instance SinkableE   SolverBinding
instance HoistableE  SolverBinding
instance RenameE     SolverBinding
instance AlphaEqE       SolverBinding
instance AlphaHashableE SolverBinding

instance GenericE (Binding c) where
  type RepE (Binding c) =
    EitherE3
      (EitherE7
          (WhenAtomName        c AtomBinding)
          (WhenC DataDefNameC  c (DataDef))
          (WhenC TyConNameC    c (DataDefName `PairE` CAtom))
          (WhenC DataConNameC  c (DataDefName `PairE` LiftE Int `PairE` CAtom))
          (WhenC ClassNameC    c (ClassDef))
          (WhenC InstanceNameC c (InstanceDef))
          (WhenC MethodNameC   c (ClassName `PairE` LiftE Int `PairE` CAtom)))
      (EitherE7
          (WhenC TopFunNameC     c (TopFun))
          (WhenC FunObjCodeNameC c (LiftE FunObjCode `PairE` LinktimeNames))
          (WhenC ModuleNameC     c (Module))
          (WhenC PtrNameC        c (LiftE (PtrType, PtrLitVal)))
          (WhenC EffectNameC     c (EffectDef))
          (WhenC HandlerNameC    c (HandlerDef))
          (WhenC EffectOpNameC   c (EffectOpDef)))
      (EitherE2
          (WhenC SpecializedDictNameC c (SpecializedDictDef))
          (WhenC ImpNameC             c (LiftE BaseType)))

  fromE = \case
    AtomNameBinding   binding           -> Case0 $ Case0 $ WhenAtomName binding
    DataDefBinding    dataDef           -> Case0 $ Case1 $ WhenC $ dataDef
    TyConBinding      dataDefName     e -> Case0 $ Case2 $ WhenC $ dataDefName `PairE` e
    DataConBinding    dataDefName idx e -> Case0 $ Case3 $ WhenC $ dataDefName `PairE` LiftE idx `PairE` e
    ClassBinding      classDef          -> Case0 $ Case4 $ WhenC $ classDef
    InstanceBinding   instanceDef       -> Case0 $ Case5 $ WhenC $ instanceDef
    MethodBinding     className idx f   -> Case0 $ Case6 $ WhenC $ className `PairE` LiftE idx `PairE` f
    TopFunBinding     fun               -> Case1 $ Case0 $ WhenC $ fun
    FunObjCodeBinding x y               -> Case1 $ Case1 $ WhenC $ LiftE x `PairE` y
    ModuleBinding m                     -> Case1 $ Case2 $ WhenC $ m
    PtrBinding ty p                     -> Case1 $ Case3 $ WhenC $ LiftE (ty,p)
    EffectBinding   effDef              -> Case1 $ Case4 $ WhenC $ effDef
    HandlerBinding  hDef                -> Case1 $ Case5 $ WhenC $ hDef
    EffectOpBinding opDef               -> Case1 $ Case6 $ WhenC $ opDef
    SpecializedDictBinding def          -> Case2 $ Case0 $ WhenC $ def
    ImpNameBinding ty                   -> Case2 $ Case1 $ WhenC $ LiftE ty
  {-# INLINE fromE #-}

  toE = \case
    Case0 (Case0 (WhenAtomName binding))                  -> AtomNameBinding   binding
    Case0 (Case1 (WhenC (dataDef)))                       -> DataDefBinding    dataDef
    Case0 (Case2 (WhenC (n `PairE` e)))                   -> TyConBinding      n e
    Case0 (Case3 (WhenC (n `PairE` LiftE idx `PairE` e))) -> DataConBinding    n idx e
    Case0 (Case4 (WhenC (classDef)))                      -> ClassBinding      classDef
    Case0 (Case5 (WhenC (instanceDef)))                   -> InstanceBinding   instanceDef
    Case0 (Case6 (WhenC ((n `PairE` LiftE i `PairE` f)))) -> MethodBinding     n i f
    Case1 (Case0 (WhenC (fun)))                           -> TopFunBinding     fun
    Case1 (Case1 (WhenC ((LiftE x `PairE` y))))           -> FunObjCodeBinding x y
    Case1 (Case2 (WhenC (m)))                             -> ModuleBinding     m
    Case1 (Case3 (WhenC ((LiftE (ty,p)))))                -> PtrBinding        ty p
    Case1 (Case4 (WhenC (effDef)))                        -> EffectBinding     effDef
    Case1 (Case5 (WhenC (hDef)))                          -> HandlerBinding    hDef
    Case1 (Case6 (WhenC (opDef)))                         -> EffectOpBinding   opDef
    Case2 (Case0 (WhenC (def)))                           -> SpecializedDictBinding def
    Case2 (Case1 (WhenC ((LiftE ty))))                    -> ImpNameBinding    ty
    _ -> error "impossible"
  {-# INLINE toE #-}

deriving via WrapE (Binding c) n instance Generic (Binding c n)
instance SinkableV         Binding
instance HoistableV        Binding
instance RenameV           Binding
instance Color c => SinkableE   (Binding c)
instance Color c => HoistableE  (Binding c)
instance Color c => RenameE     (Binding c)

instance IRRep r => GenericE (DeclBinding r) where
  type RepE (DeclBinding r) = LiftE LetAnn `PairE` Type r `PairE` Expr r
  fromE (DeclBinding ann ty expr) = LiftE ann `PairE` ty `PairE` expr
  {-# INLINE fromE #-}
  toE   (LiftE ann `PairE` ty `PairE` expr) = DeclBinding ann ty expr
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (DeclBinding r)
instance IRRep r => HoistableE     (DeclBinding r)
instance IRRep r => RenameE        (DeclBinding r)
instance IRRep r => AlphaEqE       (DeclBinding r)
instance IRRep r => AlphaHashableE (DeclBinding r)

instance GenericB (Decl r) where
  type RepB (Decl r) = AtomBinderP r (DeclBinding r)
  fromB (Let b binding) = b :> binding
  {-# INLINE fromB #-}
  toB   (b :> binding) = Let b binding
  {-# INLINE toB #-}

instance IRRep r => SinkableB      (Decl r)
instance IRRep r => HoistableB     (Decl r)
instance IRRep r => RenameB        (Decl r)
instance IRRep r => AlphaEqB       (Decl r)
instance IRRep r => AlphaHashableB (Decl r)
instance IRRep r => ProvesExt      (Decl r)
instance IRRep r => BindsNames     (Decl r)

instance IRRep r => GenericE (Effect r) where
  type RepE (Effect r) =
    EitherE4 (PairE (LiftE RWS) (Atom r))
             (LiftE (Either () ()))
             (Name EffectNameC)
             UnitE
  fromE = \case
    RWSEffect rws h    -> Case0 (PairE (LiftE rws) h)
    ExceptionEffect    -> Case1 (LiftE (Left  ()))
    IOEffect           -> Case1 (LiftE (Right ()))
    UserEffect name    -> Case2 name
    InitEffect         -> Case3 UnitE
  {-# INLINE fromE #-}
  toE = \case
    Case0 (PairE (LiftE rws) h) -> RWSEffect rws h
    Case1 (LiftE (Left  ())) -> ExceptionEffect
    Case1 (LiftE (Right ())) -> IOEffect
    Case2 name -> UserEffect name
    Case3 UnitE -> InitEffect
    _ -> error "unreachable"
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (Effect r)
instance IRRep r => HoistableE     (Effect r)
instance IRRep r => AlphaEqE       (Effect r)
instance IRRep r => AlphaHashableE (Effect r)
instance IRRep r => RenameE        (Effect r)

instance IRRep r => GenericE (EffectRow r) where
  type RepE (EffectRow r) = PairE (ListE (Effect r)) (EffectRowTail r)
  fromE (EffectRow effs ext) = ListE (eSetToList effs) `PairE` ext
  {-# INLINE fromE #-}
  toE (ListE effs `PairE` ext) = EffectRow (eSetFromList effs) ext
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (EffectRow r)
instance IRRep r => HoistableE     (EffectRow r)
instance IRRep r => RenameE        (EffectRow r)
instance IRRep r => AlphaEqE       (EffectRow r)
instance IRRep r => AlphaHashableE (EffectRow r)

instance IRRep r => GenericE (EffectRowTail r) where
  type RepE (EffectRowTail r) = EitherE (WhenCore r (AtomName CoreIR)) UnitE
  fromE = \case
    EffectRowTail v -> LeftE (WhenIRE v)
    NoTail          -> RightE UnitE
  {-# INLINE fromE #-}
  toE = \case
    LeftE (WhenIRE v) -> EffectRowTail v
    RightE UnitE    -> NoTail
  {-# INLINE toE #-}

instance IRRep r => SinkableE      (EffectRowTail r)
instance IRRep r => HoistableE     (EffectRowTail r)
instance IRRep r => RenameE        (EffectRowTail r)
instance IRRep r => AlphaEqE       (EffectRowTail r)
instance IRRep r => AlphaHashableE (EffectRowTail r)

instance IRRep r => BindsAtMostOneName (Decl r) (AtomNameC r) where
  Let b _ @> x = b @> x
  {-# INLINE (@>) #-}

instance IRRep r => BindsOneName (Decl r) (AtomNameC r) where
  binderName (Let b _) = binderName b
  {-# INLINE binderName #-}

instance Semigroup (SynthCandidates n) where
  SynthCandidates xs ys <> SynthCandidates xs' ys' =
    SynthCandidates (xs<>xs') (M.unionWith (<>) ys ys')

instance Monoid (SynthCandidates n) where
  mempty = SynthCandidates mempty mempty


instance GenericB EnvFrag where
  type RepB EnvFrag = PairB (RecSubstFrag Binding) (LiftB (MaybeE (EffectRow CoreIR)))
  fromB (EnvFrag frag (Just effs)) = PairB frag (LiftB (JustE effs))
  fromB (EnvFrag frag Nothing    ) = PairB frag (LiftB NothingE)
  toB   (PairB frag (LiftB (JustE effs))) = EnvFrag frag (Just effs)
  toB   (PairB frag (LiftB NothingE    )) = EnvFrag frag Nothing
  toB   _ = error "impossible" -- GHC exhaustiveness bug?

instance SinkableB   EnvFrag
instance HoistableB  EnvFrag
instance ProvesExt   EnvFrag
instance BindsNames  EnvFrag
instance RenameB     EnvFrag

instance GenericE PartialTopEnvFrag where
  type RepE PartialTopEnvFrag = Cache
                              `PairE` CustomRules
                              `PairE` LoadedModules
                              `PairE` LoadedObjects
                              `PairE` ModuleEnv
                              `PairE` ListE (PairE SpecDictName (ListE (LamExpr SimpIR)))
                              `PairE` ListE (PairE TopFunName (ComposeE EvalStatus TopFunLowerings))
  fromE (PartialTopEnvFrag cache rules loadedM loadedO env d fs) =
    cache `PairE` rules `PairE` loadedM `PairE` loadedO `PairE` env `PairE` d' `PairE` fs'
    where d'  = ListE $ [name `PairE` ListE methods | (name, methods) <- toList d]
          fs' = ListE $ [name `PairE` ComposeE impl | (name, impl)    <- toList fs]
  {-# INLINE fromE #-}
  toE (cache `PairE` rules `PairE` loadedM `PairE` loadedO `PairE` env `PairE` d `PairE` fs) =
    PartialTopEnvFrag cache rules loadedM loadedO env d' fs'
    where d'  = toSnocList [(name, methods) | name `PairE` ListE methods <- fromListE d]
          fs' = toSnocList [(name, impl)    | name `PairE` ComposeE impl <- fromListE fs]
  {-# INLINE toE #-}

instance SinkableE      PartialTopEnvFrag
instance HoistableE     PartialTopEnvFrag
instance RenameE        PartialTopEnvFrag

instance Semigroup (PartialTopEnvFrag n) where
  PartialTopEnvFrag x1 x2 x3 x4 x5 x6 x7 <> PartialTopEnvFrag y1 y2 y3 y4 y5 y6 y7 =
    PartialTopEnvFrag (x1<>y1) (x2<>y2) (x3<>y3) (x4<>y4) (x5<>y5) (x6<>y6) (x7 <> y7)

instance Monoid (PartialTopEnvFrag n) where
  mempty = PartialTopEnvFrag mempty mempty mempty mempty mempty mempty mempty
  mappend = (<>)

instance GenericB TopEnvFrag where
  type RepB TopEnvFrag = PairB EnvFrag (LiftB PartialTopEnvFrag)
  fromB (TopEnvFrag frag1 frag2) = PairB frag1 (LiftB frag2)
  toB   (PairB frag1 (LiftB frag2)) = TopEnvFrag frag1 frag2

instance RenameB     TopEnvFrag
instance HoistableB  TopEnvFrag
instance SinkableB TopEnvFrag
instance ProvesExt   TopEnvFrag
instance BindsNames  TopEnvFrag

instance OutFrag TopEnvFrag where
  emptyOutFrag = TopEnvFrag emptyOutFrag mempty
  {-# INLINE emptyOutFrag #-}
  catOutFrags (TopEnvFrag frag1 partial1)
              (TopEnvFrag frag2 partial2) =
    withExtEvidence frag2 $
      TopEnvFrag
        (catOutFrags frag1 frag2)
        (sink partial1 <> partial2)
  {-# INLINE catOutFrags #-}

-- XXX: unlike `ExtOutMap Env EnvFrag` instance, this once doesn't
-- extend the synthesis candidates based on the annotated let-bound names. It
-- only extends synth candidates when they're supplied explicitly.
instance ExtOutMap Env TopEnvFrag where
  extendOutMap env
    (TopEnvFrag (EnvFrag frag _)
    (PartialTopEnvFrag cache' rules' loadedM' loadedO' mEnv' d' fs')) = result''
    where
      Env (TopEnv defs rules cache loadedM loadedO) mEnv = env
      result = Env newTopEnv newModuleEnv
      result'  = foldl addMethods   result (toList d' )
      result'' = foldl addFunUpdate result' (toList fs')

      newTopEnv = withExtEvidence frag $ TopEnv
        (defs `extendRecSubst` frag)
        (sink rules <> rules')
        (sink cache <> cache')
        (sink loadedM <> loadedM')
        (sink loadedO <> loadedO')

      newModuleEnv =
        ModuleEnv
          (imports <> imports')
          (sm   <> sm'   <> newImportedSM)
          (scs  <> scs'  <> newImportedSC)
          (effs <> effs')
        where
          ModuleEnv imports sm scs effs = withExtEvidence frag $ sink mEnv
          ModuleEnv imports' sm' scs' effs' = mEnv'
          newDirectImports = S.difference (directImports imports') (directImports imports)
          newTransImports  = S.difference (transImports  imports') (transImports  imports)
          newImportedSM  = flip foldMap newDirectImports $ moduleExports         . lookupModulePure
          newImportedSC  = flip foldMap newTransImports  $ moduleSynthCandidates . lookupModulePure

      lookupModulePure v = case lookupEnvPure (Env newTopEnv mempty) v of ModuleBinding m -> m

addMethods :: Env n -> (SpecDictName n, [LamExpr SimpIR n]) -> Env n
addMethods e (dName, methods) = do
  let SpecializedDictBinding (SpecializedDict dAbs oldMethods) = lookupEnvPure e dName
  case oldMethods of
    Nothing -> do
      let newBinding = SpecializedDictBinding $ SpecializedDict dAbs (Just methods)
      updateEnv dName newBinding e
    Just _ -> error "shouldn't be adding methods if we already have them"

addFunUpdate :: Env n -> (TopFunName n, TopFunEvalStatus n) -> Env n
addFunUpdate e (f, s) = do
  case lookupEnvPure e f of
    TopFunBinding (DexTopFun def ty simp _) ->
      updateEnv f (TopFunBinding $ DexTopFun def ty simp s) e
    _ -> error "can't update ffi function impl"

lookupEnvPure :: Color c => Env n -> Name c n -> Binding c n
lookupEnvPure env v = lookupTerminalSubstFrag (fromRecSubst $ envDefs $ topEnv env) v

instance GenericE Module where
  type RepE Module =       LiftE ModuleSourceName
                   `PairE` ListE ModuleName
                   `PairE` ListE ModuleName
                   `PairE` SourceMap
                   `PairE` SynthCandidates

  fromE (Module name deps transDeps sm sc) =
    LiftE name `PairE` ListE (S.toList deps) `PairE` ListE (S.toList transDeps)
      `PairE` sm `PairE` sc
  {-# INLINE fromE #-}

  toE (LiftE name `PairE` ListE deps `PairE` ListE transDeps
         `PairE` sm `PairE` sc) =
    Module name (S.fromList deps) (S.fromList transDeps) sm sc
  {-# INLINE toE #-}

instance SinkableE      Module
instance HoistableE     Module
instance AlphaEqE       Module
instance AlphaHashableE Module
instance RenameE        Module

instance GenericE ImportStatus where
  type RepE ImportStatus = ListE ModuleName `PairE` ListE ModuleName
  fromE (ImportStatus direct trans) = ListE (S.toList direct)
                              `PairE` ListE (S.toList trans)
  {-# INLINE fromE #-}
  toE (ListE direct `PairE` ListE trans) =
    ImportStatus (S.fromList direct) (S.fromList trans)
  {-# INLINE toE #-}

instance SinkableE      ImportStatus
instance HoistableE     ImportStatus
instance AlphaEqE       ImportStatus
instance AlphaHashableE ImportStatus
instance RenameE        ImportStatus

instance Semigroup (ImportStatus n) where
  ImportStatus direct trans <> ImportStatus direct' trans' =
    ImportStatus (direct <> direct') (trans <> trans')

instance Monoid (ImportStatus n) where
  mappend = (<>)
  mempty = ImportStatus mempty mempty

instance GenericE LoadedModules where
  type RepE LoadedModules = ListE (PairE (LiftE ModuleSourceName) ModuleName)
  fromE (LoadedModules m) =
    ListE $ M.toList m <&> \(v,md) -> PairE (LiftE v) md
  {-# INLINE fromE #-}
  toE (ListE pairs) =
    LoadedModules $ M.fromList $ pairs <&> \(PairE (LiftE v) md) -> (v, md)
  {-# INLINE toE #-}

instance SinkableE      LoadedModules
instance HoistableE     LoadedModules
instance AlphaEqE       LoadedModules
instance AlphaHashableE LoadedModules
instance RenameE        LoadedModules

instance GenericE LoadedObjects where
  type RepE LoadedObjects = ListE (PairE FunObjCodeName (LiftE NativeFunction))
  fromE (LoadedObjects m) =
    ListE $ M.toList m <&> \(v,p) -> PairE v (LiftE p)
  {-# INLINE fromE #-}
  toE (ListE pairs) =
    LoadedObjects $ M.fromList $ pairs <&> \(PairE v (LiftE p)) -> (v, p)
  {-# INLINE toE #-}

instance SinkableE      LoadedObjects
instance HoistableE     LoadedObjects
instance RenameE        LoadedObjects

instance GenericE ModuleEnv where
  type RepE ModuleEnv = ImportStatus
                `PairE` SourceMap
                `PairE` SynthCandidates
                `PairE` EffectRow CoreIR
  fromE (ModuleEnv imports sm sc eff) =
    imports `PairE` sm `PairE` sc `PairE` eff
  {-# INLINE fromE #-}
  toE (imports `PairE` sm `PairE` sc `PairE` eff) =
    ModuleEnv imports sm sc eff
  {-# INLINE toE #-}

instance SinkableE      ModuleEnv
instance HoistableE     ModuleEnv
instance AlphaEqE       ModuleEnv
instance AlphaHashableE ModuleEnv
instance RenameE        ModuleEnv

instance Semigroup (ModuleEnv n) where
  ModuleEnv x1 x2 x3 x4 <> ModuleEnv y1 y2 y3 y4 =
    ModuleEnv (x1<>y1) (x2<>y2) (x3<>y3) (x4<>y4)

instance Monoid (ModuleEnv n) where
  mempty = ModuleEnv mempty mempty mempty mempty

instance Semigroup (LoadedModules n) where
  LoadedModules m1 <> LoadedModules m2 = LoadedModules (m2 <> m1)

instance Monoid (LoadedModules n) where
  mempty = LoadedModules mempty

instance Semigroup (LoadedObjects n) where
  LoadedObjects m1 <> LoadedObjects m2 = LoadedObjects (m2 <> m1)

instance Monoid (LoadedObjects n) where
  mempty = LoadedObjects mempty

instance Hashable Projection
instance Hashable IxMethod
instance Hashable ParamRole
instance Hashable a => Hashable (EvalStatus a)

instance IRRep r => Store (RepVal r n)
instance IRRep r => Store (Atom r n)
instance IRRep r => Store (Expr r n)
instance Store (SimpInCore n)
instance Store (SolverBinding n)
instance IRRep r => Store (AtomBinding r n)
instance Store (SpecializationSpec n)
instance Store (LinearizationSpec n)
instance Store (LamBinding n)
instance IRRep r => Store (DeclBinding r n)
instance Store (FieldRowElem  n)
instance Store (FieldRowElems n)
instance IRRep r => Store (Decl r n l)
instance Store (RolePiBinder n l)
instance Store (DataDefParams n)
instance Store (DataDef n)
instance Store (DataConDef n)
instance IRRep r => Store (Block r n)
instance IRRep r => Store (LamExpr r n)
instance IRRep r => Store (IxType r n)
instance Store (PiBinding n)
instance Store (PiBinder n l)
instance Store (PiType n)
instance IRRep r => Store (TabPiType r n)
instance IRRep r => Store (DepPairType  r n)
instance Store (SuperclassBinders n l)
instance Store (AtomRules n)
instance Store (ClassDef     n)
instance Store (InstanceDef  n)
instance Store (InstanceBody n)
instance Store (MethodType   n)
instance Store (DictType n)
instance Store (DictExpr n)
instance Store (EffectDef n)
instance Store (EffectOpDef n)
instance Store (HandlerDef n)
instance Store (EffectOpType n)
instance Store (EffectOpIdx)
instance Store (SynthCandidates n)
instance Store (Module n)
instance Store (ImportStatus n)
instance Store (TopFunLowerings n)
instance Store a => Store (EvalStatus a)
instance Store (TopFun n)
instance Store (TopFunDef n)
instance Color c => Store (Binding c n)
instance Store (NoInlineDef n)
instance Store (ModuleEnv n)
instance Store (SerializedEnv n)
instance Store (ann n) => Store (NonDepNest r ann n l)
instance Store Projection
instance Store IxMethod
instance Store ParamRole
instance Store (SpecializedDictDef n)
instance IRRep r => Store (Hof r n)
instance IRRep r => Store (RefOp r n)
instance IRRep r => Store (BaseMonoid r n)
instance IRRep r => Store (DAMOp r n)
instance IRRep r => Store (IxDict r n)
instance Store (UserEffectOp n)
instance Store (NewtypeCon n)
instance Store (NewtypeTyCon n)
