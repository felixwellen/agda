{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Agda.TypeChecking.Monad.Base where

import Prelude hiding (null)

import qualified Control.Concurrent as C
import qualified Control.Exception as E
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Writer hiding ((<>))
import Control.Monad.Trans.Maybe
import Control.Applicative hiding (empty)

import Data.Function
import Data.Int
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import qualified Data.List as List
import Data.Maybe
import Data.Map (Map)
import qualified Data.Map as Map -- hiding (singleton, null, empty)
import Data.Monoid ( Monoid, mempty, mappend )
import Data.Set (Set)
import qualified Data.Set as Set -- hiding (singleton, null, empty)
import Data.Semigroup ( Semigroup, (<>), Any(..) )
import Data.Data (Data, toConstr)
import Data.Foldable (Foldable)
import Data.Traversable
import Data.IORef

import qualified System.Console.Haskeline as Haskeline

import Agda.Benchmarking (Benchmark, Phase)

import Agda.Syntax.Concrete (TopLevelModuleName)
import Agda.Syntax.Common
import qualified Agda.Syntax.Concrete as C
import Agda.Syntax.Concrete.Definitions
  (NiceDeclaration, DeclarationWarning, declarationWarningName)
import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Abstract (AllNames)
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.Pattern ()
import Agda.Syntax.Internal.Generic (TermLike(..))
import Agda.Syntax.Literal
import Agda.Syntax.Parser (PM(..), ParseWarning, runPMIO)
import Agda.Syntax.Parser.Monad (parseWarningName)
import Agda.Syntax.Treeless (Compiled)
import Agda.Syntax.Fixity
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import qualified Agda.Syntax.Info as Info

import Agda.TypeChecking.CompiledClause
import Agda.TypeChecking.Positivity.Occurrence
import Agda.TypeChecking.Free.Lazy (Free(freeVars'), bind', bind)

import {-# SOURCE #-} Agda.Compiler.Backend

-- import {-# SOURCE #-} Agda.Interaction.FindFile
import Agda.Interaction.Options
import Agda.Interaction.Options.Warnings
import Agda.Interaction.Response
  (InteractionOutputCallback, defaultInteractionOutputCallback, Response(..))
import Agda.Interaction.Highlighting.Precise
  (CompressedFile, HighlightingInfo)

import Agda.Utils.Except
  ( Error(strMsg)
  , ExceptT
  , MonadError(catchError, throwError)
  , runExceptT
  , mapExceptT
  )

import Agda.Utils.Benchmark (MonadBench(..))
import Agda.Utils.FileName
import Agda.Utils.HashMap (HashMap)
import qualified Agda.Utils.HashMap as HMap
import Agda.Utils.Hash
import Agda.Utils.Lens
import Agda.Utils.List
import Agda.Utils.ListT
import Agda.Utils.Monad
import Agda.Utils.NonemptyList
import Agda.Utils.Null
import Agda.Utils.Permutation
import Agda.Utils.Pretty hiding ((<>))
import qualified Agda.Utils.Pretty as P
import Agda.Utils.Singleton
import Agda.Utils.Functor
import Agda.Utils.Function

#include "undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Type checking state
---------------------------------------------------------------------------

data TCState = TCSt
  { stPreScopeState   :: !PreScopeState
    -- ^ The state which is frozen after scope checking.
  , stPostScopeState  :: !PostScopeState
    -- ^ The state which is modified after scope checking.
  , stPersistentState :: !PersistentTCState
    -- ^ State which is forever, like a diamond.
  }

class Monad m => ReadTCState m where
  getTCState :: m TCState
  withTCState :: (TCState -> TCState) -> m a -> m a

instance ReadTCState m => ReadTCState (MaybeT m) where
  getTCState = lift getTCState
  withTCState = mapMaybeT . withTCState

instance ReadTCState m => ReadTCState (ListT m) where
  getTCState = lift getTCState
  withTCState f = ListT . withTCState f . runListT

instance ReadTCState m => ReadTCState (ExceptT err m) where
  getTCState = lift getTCState
  withTCState = mapExceptT . withTCState

instance ReadTCState m => ReadTCState (ReaderT r m) where
  getTCState = lift getTCState
  withTCState = mapReaderT . withTCState

instance (Monoid w, ReadTCState m) => ReadTCState (WriterT w m) where
  getTCState = lift getTCState
  withTCState = mapWriterT . withTCState

instance ReadTCState m => ReadTCState (StateT s m) where
  getTCState = lift getTCState
  withTCState = mapStateT . withTCState

instance Show TCState where
  show _ = "TCSt{}"

data PreScopeState = PreScopeState
  { stPreTokens             :: !CompressedFile -- from lexer
    -- ^ Highlighting info for tokens (but not those tokens for
    -- which highlighting exists in 'stSyntaxInfo').
  , stPreImports            :: !Signature  -- XX populated by scopec hecker
    -- ^ Imported declared identifiers.
    --   Those most not be serialized!
  , stPreImportedModules    :: !(Set ModuleName)  -- imports logic
  , stPreModuleToSource     :: !ModuleToSource   -- imports
  , stPreVisitedModules     :: !VisitedModules   -- imports
  , stPreScope              :: !ScopeInfo
    -- generated by scope checker, current file: which modules you have, public definitions, current file, maps concrete names to abstract names.
  , stPrePatternSyns        :: !A.PatternSynDefns
    -- ^ Pattern synonyms of the current file.  Serialized.
  , stPrePatternSynImports  :: !A.PatternSynDefns
    -- ^ Imported pattern synonyms.  Must not be serialized!
  , stPreGeneralizedVars    :: !(Maybe (Set QName))
    -- ^ Collected generalizable variables; used during scope checking of terms
  , stPrePragmaOptions      :: !PragmaOptions
    -- ^ Options applying to the current file. @OPTIONS@
    -- pragmas only affect this field.
  , stPreImportedBuiltins   :: !(BuiltinThings PrimFun)
  , stPreImportedDisplayForms :: !DisplayForms
    -- ^ Display forms added by someone else to imported identifiers
  , stPreImportedInstanceDefs :: !InstanceTable
  , stPreForeignCode        :: !(Map BackendName [ForeignCode])
    -- ^ @{-# FOREIGN #-}@ code that should be included in the compiled output.
    -- Does not include code for imported modules.
  , stPreFreshInteractionId :: !InteractionId
  , stPreUserWarnings       :: !(Map A.QName String)
  }

type DisambiguatedNames = IntMap A.QName

data PostScopeState = PostScopeState
  { stPostSyntaxInfo          :: !CompressedFile
    -- ^ Highlighting info.
  , stPostDisambiguatedNames  :: !DisambiguatedNames
    -- ^ Disambiguation carried out by the type checker.
    --   Maps position of first name character to disambiguated @'A.QName'@
    --   for each @'A.AmbiguousQName'@ already passed by the type checker.
  , stPostMetaStore           :: !MetaStore
  , stPostInteractionPoints   :: !InteractionPoints -- scope checker first
  , stPostAwakeConstraints    :: !Constraints
  , stPostSleepingConstraints :: !Constraints
  , stPostDirty               :: !Bool -- local
    -- ^ Dirty when a constraint is added, used to prevent pointer update.
    -- Currently unused.
  , stPostOccursCheckDefs     :: !(Set QName) -- local
    -- ^ Definitions to be considered during occurs check.
    --   Initialized to the current mutual block before the check.
    --   During occurs check, we remove definitions from this set
    --   as soon we have checked them.
  , stPostSignature           :: !Signature
    -- ^ Declared identifiers of the current file.
    --   These will be serialized after successful type checking.
  , stPostModuleCheckpoints   :: !(Map ModuleName CheckpointId)
    -- ^ For each module remember the checkpoint corresponding to the orignal
    --   context of the module parameters.
  , stPostImportsDisplayForms :: !DisplayForms
    -- ^ Display forms we add for imported identifiers
  , stPostCurrentModule       :: !(Maybe ModuleName)
    -- ^ The current module is available after it has been type
    -- checked.
  , stPostInstanceDefs        :: !TempInstanceTable
  , stPostStatistics          :: !Statistics
    -- ^ Counters to collect various statistics about meta variables etc.
    --   Only for current file.
  , stPostTCWarnings          :: ![TCWarning]
  , stPostMutualBlocks        :: !(Map MutualId MutualBlock)
  , stPostLocalBuiltins       :: !(BuiltinThings PrimFun)
  , stPostFreshMetaId         :: !MetaId
  , stPostFreshMutualId       :: !MutualId
  , stPostFreshProblemId      :: !ProblemId
  , stPostFreshCheckpointId   :: !CheckpointId
  , stPostFreshInt            :: !Int
  , stPostFreshNameId         :: !NameId
  , stPostAreWeCaching        :: !Bool
  }

-- | A mutual block of names in the signature.
data MutualBlock = MutualBlock
  { mutualInfo  :: Info.MutualInfo
    -- ^ The original info of the mutual block.
  , mutualNames :: Set QName
  } deriving (Show, Eq)

instance Null MutualBlock where
  empty = MutualBlock empty empty

-- | A part of the state which is not reverted when an error is thrown
-- or the state is reset.
data PersistentTCState = PersistentTCSt
  { stDecodedModules    :: DecodedModules
  , stPersistentOptions :: CommandLineOptions
  , stInteractionOutputCallback  :: InteractionOutputCallback
    -- ^ Callback function to call when there is a response
    --   to give to the interactive frontend.
    --   See the documentation of 'InteractionOutputCallback'.
  , stBenchmark         :: !Benchmark
    -- ^ Structure to track how much CPU time was spent on which Agda phase.
    --   Needs to be a strict field to avoid space leaks!
  , stAccumStatistics   :: !Statistics
    -- ^ Should be strict field.
  , stLoadedFileCache   :: !(Maybe LoadedFileCache)
    -- ^ Cached typechecking state from the last loaded file.
    --   Should be Nothing when checking imports.
  , stPersistBackends   :: [Backend]
    -- ^ Current backends with their options
  }

data LoadedFileCache = LoadedFileCache
  { lfcCached  :: !CachedTypeCheckLog
  , lfcCurrent :: !CurrentTypeCheckLog
  }

-- | A log of what the type checker does and states after the action is
-- completed.  The cached version is stored first executed action first.
type CachedTypeCheckLog = [(TypeCheckAction, PostScopeState)]

-- | Like 'CachedTypeCheckLog', but storing the log for an ongoing type
-- checking of a module.  Stored in reverse order (last performed action
-- first).
type CurrentTypeCheckLog = [(TypeCheckAction, PostScopeState)]

-- | A complete log for a module will look like this:
--
--   * 'Pragmas'
--
--   * 'EnterSection', entering the main module.
--
--   * 'Decl'/'EnterSection'/'LeaveSection', for declarations and nested
--     modules
--
--   * 'LeaveSection', leaving the main module.
data TypeCheckAction
  = EnterSection !Info.ModuleInfo !ModuleName ![A.TypedBindings]
  | LeaveSection !ModuleName
  | Decl !A.Declaration
    -- ^ Never a Section or ScopeDecl
  | Pragmas !PragmaOptions

-- | Empty persistent state.

initPersistentState :: PersistentTCState
initPersistentState = PersistentTCSt
  { stPersistentOptions         = defaultOptions
  , stDecodedModules            = Map.empty
  , stInteractionOutputCallback = defaultInteractionOutputCallback
  , stBenchmark                 = empty
  , stAccumStatistics           = Map.empty
  , stLoadedFileCache           = Nothing
  , stPersistBackends           = []
  }

-- | Empty state of type checker.

initPreScopeState :: PreScopeState
initPreScopeState = PreScopeState
  { stPreTokens               = mempty
  , stPreImports              = emptySignature
  , stPreImportedModules      = Set.empty
  , stPreModuleToSource       = Map.empty
  , stPreVisitedModules       = Map.empty
  , stPreScope                = emptyScopeInfo
  , stPrePatternSyns          = Map.empty
  , stPrePatternSynImports    = Map.empty
  , stPreGeneralizedVars      = mempty
  , stPrePragmaOptions        = defaultInteractionOptions
  , stPreImportedBuiltins     = Map.empty
  , stPreImportedDisplayForms = HMap.empty
  , stPreImportedInstanceDefs = Map.empty
  , stPreForeignCode          = Map.empty
  , stPreFreshInteractionId   = 0
  , stPreUserWarnings         = Map.empty
  }

initPostScopeState :: PostScopeState
initPostScopeState = PostScopeState
  { stPostSyntaxInfo           = mempty
  , stPostDisambiguatedNames   = IntMap.empty
  , stPostMetaStore            = Map.empty
  , stPostInteractionPoints    = Map.empty
  , stPostAwakeConstraints     = []
  , stPostSleepingConstraints  = []
  , stPostDirty                = False
  , stPostOccursCheckDefs      = Set.empty
  , stPostSignature            = emptySignature
  , stPostModuleCheckpoints    = Map.empty
  , stPostImportsDisplayForms  = HMap.empty
  , stPostCurrentModule        = Nothing
  , stPostInstanceDefs         = (Map.empty , Set.empty)
  , stPostStatistics           = Map.empty
  , stPostTCWarnings           = []
  , stPostMutualBlocks         = Map.empty
  , stPostLocalBuiltins        = Map.empty
  , stPostFreshMetaId          = 0
  , stPostFreshMutualId        = 0
  , stPostFreshProblemId       = 1
  , stPostFreshCheckpointId    = 1
  , stPostFreshInt             = 0
  , stPostFreshNameId           = NameId 0 0
  , stPostAreWeCaching         = False
  }

initState :: TCState
initState = TCSt
  { stPreScopeState   = initPreScopeState
  , stPostScopeState  = initPostScopeState
  , stPersistentState = initPersistentState
  }

-- * st-prefixed lenses
------------------------------------------------------------------------

stTokens :: Lens' CompressedFile TCState
stTokens f s =
  f (stPreTokens (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreTokens = x}}

stImports :: Lens' Signature TCState
stImports f s =
  f (stPreImports (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImports = x}}

stImportedModules :: Lens' (Set ModuleName) TCState
stImportedModules f s =
  f (stPreImportedModules (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedModules = x}}

stModuleToSource :: Lens' ModuleToSource TCState
stModuleToSource f s =
  f (stPreModuleToSource (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreModuleToSource = x}}

stVisitedModules :: Lens' VisitedModules TCState
stVisitedModules f s =
  f (stPreVisitedModules (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreVisitedModules = x}}

stScope :: Lens' ScopeInfo TCState
stScope f s =
  f (stPreScope (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreScope = x}}

stPatternSyns :: Lens' A.PatternSynDefns TCState
stPatternSyns f s =
  f (stPrePatternSyns (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePatternSyns = x}}

stPatternSynImports :: Lens' A.PatternSynDefns TCState
stPatternSynImports f s =
  f (stPrePatternSynImports (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePatternSynImports = x}}

stGeneralizedVars :: Lens' (Maybe (Set QName)) TCState
stGeneralizedVars f s =
  f (stPreGeneralizedVars (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreGeneralizedVars = x}}

stPragmaOptions :: Lens' PragmaOptions TCState
stPragmaOptions f s =
  f (stPrePragmaOptions (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPrePragmaOptions = x}}

stImportedBuiltins :: Lens' (BuiltinThings PrimFun) TCState
stImportedBuiltins f s =
  f (stPreImportedBuiltins (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedBuiltins = x}}

stForeignCode :: Lens' (Map BackendName [ForeignCode]) TCState
stForeignCode f s =
  f (stPreForeignCode (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreForeignCode = x}}

stFreshInteractionId :: Lens' InteractionId TCState
stFreshInteractionId f s =
  f (stPreFreshInteractionId (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreFreshInteractionId = x}}

stUserWarnings :: Lens' (Map A.QName String) TCState
stUserWarnings f s =
  f (stPreUserWarnings (stPreScopeState s)) <&>
  \ x -> s {stPreScopeState = (stPreScopeState s) {stPreUserWarnings = x}}

stBackends :: Lens' [Backend] TCState
stBackends f s =
  f (stPersistBackends (stPersistentState s)) <&>
  \x -> s {stPersistentState = (stPersistentState s) {stPersistBackends = x}}

stFreshNameId :: Lens' NameId TCState
stFreshNameId f s =
  f (stPostFreshNameId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshNameId = x}}

stSyntaxInfo :: Lens' CompressedFile TCState
stSyntaxInfo f s =
  f (stPostSyntaxInfo (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSyntaxInfo = x}}

stDisambiguatedNames :: Lens' DisambiguatedNames TCState
stDisambiguatedNames f s =
  f (stPostDisambiguatedNames (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostDisambiguatedNames = x}}

stMetaStore :: Lens' MetaStore TCState
stMetaStore f s =
  f (stPostMetaStore (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostMetaStore = x}}

stInteractionPoints :: Lens' InteractionPoints TCState
stInteractionPoints f s =
  f (stPostInteractionPoints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostInteractionPoints = x}}

stAwakeConstraints :: Lens' Constraints TCState
stAwakeConstraints f s =
  f (stPostAwakeConstraints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostAwakeConstraints = x}}

stSleepingConstraints :: Lens' Constraints TCState
stSleepingConstraints f s =
  f (stPostSleepingConstraints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSleepingConstraints = x}}

stDirty :: Lens' Bool TCState
stDirty f s =
  f (stPostDirty (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostDirty = x}}

stOccursCheckDefs :: Lens' (Set QName) TCState
stOccursCheckDefs f s =
  f (stPostOccursCheckDefs (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostOccursCheckDefs = x}}

stSignature :: Lens' Signature TCState
stSignature f s =
  f (stPostSignature (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostSignature = x}}

stModuleCheckpoints :: Lens' (Map ModuleName CheckpointId) TCState
stModuleCheckpoints f s =
  f (stPostModuleCheckpoints (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostModuleCheckpoints = x}}

stImportsDisplayForms :: Lens' DisplayForms TCState
stImportsDisplayForms f s =
  f (stPostImportsDisplayForms (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostImportsDisplayForms = x}}

stImportedDisplayForms :: Lens' DisplayForms TCState
stImportedDisplayForms f s =
  f (stPreImportedDisplayForms (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedDisplayForms = x}}

stCurrentModule :: Lens' (Maybe ModuleName) TCState
stCurrentModule f s =
  f (stPostCurrentModule (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostCurrentModule = x}}

stImportedInstanceDefs :: Lens' InstanceTable TCState
stImportedInstanceDefs f s =
  f (stPreImportedInstanceDefs (stPreScopeState s)) <&>
  \x -> s {stPreScopeState = (stPreScopeState s) {stPreImportedInstanceDefs = x}}

stInstanceDefs :: Lens' TempInstanceTable TCState
stInstanceDefs f s =
  f (stPostInstanceDefs (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostInstanceDefs = x}}

stStatistics :: Lens' Statistics TCState
stStatistics f s =
  f (stPostStatistics (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostStatistics = x}}

stTCWarnings :: Lens' [TCWarning] TCState
stTCWarnings f s =
  f (stPostTCWarnings (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostTCWarnings = x}}

stMutualBlocks :: Lens' (Map MutualId MutualBlock) TCState
stMutualBlocks f s =
  f (stPostMutualBlocks (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostMutualBlocks = x}}

stLocalBuiltins :: Lens' (BuiltinThings PrimFun) TCState
stLocalBuiltins f s =
  f (stPostLocalBuiltins (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostLocalBuiltins = x}}

stFreshMetaId :: Lens' MetaId TCState
stFreshMetaId f s =
  f (stPostFreshMetaId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshMetaId = x}}

stFreshMutualId :: Lens' MutualId TCState
stFreshMutualId f s =
  f (stPostFreshMutualId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshMutualId = x}}

stFreshProblemId :: Lens' ProblemId TCState
stFreshProblemId f s =
  f (stPostFreshProblemId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshProblemId = x}}

stFreshCheckpointId :: Lens' CheckpointId TCState
stFreshCheckpointId f s =
  f (stPostFreshCheckpointId (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshCheckpointId = x}}

stFreshInt :: Lens' Int TCState
stFreshInt f s =
  f (stPostFreshInt (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostFreshInt = x}}

-- use @areWeCaching@ from the Caching module instead.
stAreWeCaching :: Lens' Bool TCState
stAreWeCaching f s =
  f (stPostAreWeCaching (stPostScopeState s)) <&>
  \x -> s {stPostScopeState = (stPostScopeState s) {stPostAreWeCaching = x}}

stBuiltinThings :: TCState -> BuiltinThings PrimFun
stBuiltinThings s = (s^.stLocalBuiltins) `Map.union` (s^.stImportedBuiltins)

-- * Fresh things
------------------------------------------------------------------------

class Enum i => HasFresh i where
    freshLens :: Lens' i TCState
    nextFresh' :: i -> i
    nextFresh' = succ

nextFresh :: HasFresh i => TCState -> (i, TCState)
nextFresh s =
  let !c = s^.freshLens
  in (c, set freshLens (nextFresh' c) s)

fresh :: (HasFresh i, MonadState TCState m) => m i
fresh =
    do  !s <- get
        let (!c , !s') = nextFresh s
        put s'
        return c

instance HasFresh MetaId where
  freshLens = stFreshMetaId

instance HasFresh MutualId where
  freshLens = stFreshMutualId

instance HasFresh InteractionId where
  freshLens = stFreshInteractionId

instance HasFresh NameId where
  freshLens = stFreshNameId
  -- nextFresh increments the current fresh name by 2 so @NameId@s used
  -- before caching starts do not overlap with the ones used after.
  nextFresh' = succ . succ

instance HasFresh Int where
  freshLens = stFreshInt

newtype ProblemId = ProblemId Nat
  deriving (Data, Eq, Ord, Enum, Real, Integral, Num)

-- TODO: 'Show' should output Haskell-parseable representations.
-- The following instance is deprecated, and Pretty[TCM] should be used
-- instead. Later, simply derive Show for this type.

-- ASR (28 December 2014). This instance is not used anymore (module
-- the test suite) when reporting errors. See Issue 1293.

-- This particular Show instance is ok because of the Num instance.
instance Show ProblemId where
  show (ProblemId n) = show n

instance Pretty ProblemId where
  pretty (ProblemId n) = pretty n

instance HasFresh ProblemId where
  freshLens = stFreshProblemId

newtype CheckpointId = CheckpointId Int
  deriving (Data, Eq, Ord, Enum, Real, Integral, Num)

instance Show CheckpointId where
  show (CheckpointId n) = show n

instance Pretty CheckpointId where
  pretty (CheckpointId n) = pretty n

instance HasFresh CheckpointId where
  freshLens = stFreshCheckpointId

freshName :: MonadState TCState m => Range -> String -> m Name
freshName r s = do
  i <- fresh
  return $ mkName r i s

freshNoName :: MonadState TCState m => Range -> m Name
freshNoName r =
    do  i <- fresh
        return $ Name i (C.NoName noRange i) r noFixity'

freshNoName_ :: MonadState TCState m => m Name
freshNoName_ = freshNoName noRange

-- | Create a fresh name from @a@.
class FreshName a where
  freshName_ :: MonadState TCState m => a -> m Name

instance FreshName (Range, String) where
  freshName_ = uncurry freshName

instance FreshName String where
  freshName_ = freshName noRange

instance FreshName Range where
  freshName_ = freshNoName

instance FreshName () where
  freshName_ () = freshNoName_

---------------------------------------------------------------------------
-- ** Managing file names
---------------------------------------------------------------------------

-- | Maps top-level module names to the corresponding source file
-- names.

type ModuleToSource = Map TopLevelModuleName AbsolutePath

-- | Maps source file names to the corresponding top-level module
-- names.

type SourceToModule = Map AbsolutePath TopLevelModuleName

-- | Creates a 'SourceToModule' map based on 'stModuleToSource'.
--
--   O(n log n).
--
--   For a single reverse lookup in 'stModuleToSource',
--   rather use 'lookupModuleFromSourse'.

sourceToModule :: TCM SourceToModule
sourceToModule =
  Map.fromList
     .  List.map (\(m, f) -> (f, m))
     .  Map.toList
    <$> use stModuleToSource

-- | Lookup an 'AbsolutePath' in 'sourceToModule'.
--
--   O(n).

lookupModuleFromSource :: AbsolutePath -> TCM (Maybe TopLevelModuleName)
lookupModuleFromSource f =
  fmap fst . List.find ((f ==) . snd) . Map.toList <$> use stModuleToSource

---------------------------------------------------------------------------
-- ** Interface
---------------------------------------------------------------------------

data ModuleInfo = ModuleInfo
  { miInterface  :: Interface
  , miWarnings   :: Bool
    -- ^ 'True' if warnings were encountered when the module was type
    -- checked.
  }

-- Note that the use of 'C.TopLevelModuleName' here is a potential
-- performance problem, because these names do not contain unique
-- identifiers.

type VisitedModules = Map C.TopLevelModuleName ModuleInfo
type DecodedModules = Map C.TopLevelModuleName Interface

data ForeignCode = ForeignCode Range String
  deriving Show

data Interface = Interface
  { iSourceHash      :: Hash
    -- ^ Hash of the source code.
  , iImportedModules :: [(ModuleName, Hash)]
    -- ^ Imported modules and their hashes.
  , iModuleName      :: ModuleName
    -- ^ Module name of this interface.
  , iScope           :: Map ModuleName Scope
    -- ^ Scope defined by this module.
    --
    --   Andreas, AIM XX: Too avoid duplicate serialization, this field is
    --   not serialized, so if you deserialize an interface, @iScope@
    --   will be empty.
    --   But 'constructIScope' constructs 'iScope' from 'iInsideScope'.
  , iInsideScope     :: ScopeInfo
    -- ^ Scope after we loaded this interface.
    --   Used in 'Agda.Interaction.BasicOps.AtTopLevel'
    --   and     'Agda.Interaction.CommandLine.interactionLoop'.
  , iSignature       :: Signature
  , iDisplayForms    :: DisplayForms
    -- ^ Display forms added for imported identifiers.
  , iUserWarnings    :: Map A.QName String
    -- ^ User warnings for imported identifiers
  , iBuiltin         :: BuiltinThings (String, QName)
  , iForeignCode     :: Map BackendName [ForeignCode]
  , iHighlighting    :: HighlightingInfo
  , iPragmaOptions   :: [OptionsPragma]
                        -- ^ Pragma options set in the file.
  , iPatternSyns     :: A.PatternSynDefns
  , iWarnings        :: [TCWarning]
  }
  deriving Show

instance Pretty Interface where
  pretty (Interface sourceH importedM moduleN scope insideS signature display
                    userwarn builtin foreignCode highlighting pragmaO patternS
                    warnings) =
    hang (text "Interface") 2 $ vcat
      [ text "source hash:"         <+> (pretty . show) sourceH
      , text "imported modules:"    <+> (pretty . show) importedM
      , text "module name:"         <+> pretty moduleN
      , text "scope:"               <+> (pretty . show) scope
      , text "inside scope:"        <+> (pretty . show) insideS
      , text "signature:"           <+> (pretty . show) signature
      , text "display:"             <+> (pretty . show) display
      , text "user warnings:"       <+> (pretty . show) userwarn
      , text "builtin:"             <+> (pretty . show) builtin
      , text "Foreign code:"        <+> (pretty . show) foreignCode
      , text "highlighting:"        <+> (pretty . show) highlighting
      , text "pragma options:"      <+> (pretty . show) pragmaO
      , text "pattern syns:"        <+> (pretty . show) patternS
      , text "warnings:"            <+> (pretty . show) warnings
      ]

-- | Combines the source hash and the (full) hashes of the imported modules.
iFullHash :: Interface -> Hash
iFullHash i = combineHashes $ iSourceHash i : List.map snd (iImportedModules i)

---------------------------------------------------------------------------
-- ** Closure
---------------------------------------------------------------------------

data Closure a = Closure
  { clSignature        :: Signature
  , clEnv              :: TCEnv
  , clScope            :: ScopeInfo
  , clModuleCheckpoints :: Map ModuleName CheckpointId
  , clValue            :: a
  }
    deriving (Data, Functor, Foldable)

instance Show a => Show (Closure a) where
  show cl = "Closure { clValue = " ++ show (clValue cl) ++ " }"

instance HasRange a => HasRange (Closure a) where
    getRange = getRange . clValue

buildClosure :: a -> TCM (Closure a)
buildClosure x = do
    env   <- ask
    sig   <- use stSignature
    scope <- use stScope
    cps   <- use stModuleCheckpoints
    return $ Closure sig env scope cps x

---------------------------------------------------------------------------
-- ** Constraints
---------------------------------------------------------------------------

type Constraints = [ProblemConstraint]

data ProblemConstraint = PConstr
  { constraintProblems :: Set ProblemId
  , theConstraint      :: Closure Constraint
  }
  deriving (Data, Show)

instance HasRange ProblemConstraint where
  getRange = getRange . theConstraint

data Constraint
  = ValueCmp Comparison Type Term Term
  | ValueCmpOnFace Comparison Term Type Term Term
  | ElimCmp [Polarity] [IsForced] Type Term [Elim] [Elim]
  | TypeCmp Comparison Type Type
  | TelCmp Type Type Comparison Telescope Telescope -- ^ the two types are for the error message only
  | SortCmp Comparison Sort Sort
  | LevelCmp Comparison Level Level
--  | ShortCut MetaId Term Type
--    -- ^ A delayed instantiation.  Replaces @ValueCmp@ in 'postponeTypeCheckingProblem'.
  | HasBiggerSort Sort
  | HasPTSRule Sort (Abs Sort)
  | UnBlock MetaId
  | Guarded Constraint ProblemId
  | IsEmpty Range Type
    -- ^ The range is the one of the absurd pattern.
  | CheckSizeLtSat Term
    -- ^ Check that the 'Term' is either not a SIZELT or a non-empty SIZELT.
  | FindInScope MetaId (Maybe MetaId) (Maybe [Candidate])
    -- ^ the first argument is the instance argument, the second one is the meta
    --   on which the constraint may be blocked on and the third one is the list
    --   of candidates (or Nothing if we haven’t determined the list of
    --   candidates yet)
  | CheckFunDef Delayed Info.DefInfo QName [A.Clause]
  deriving (Data, Show)

instance HasRange Constraint where
  getRange (IsEmpty r t) = r
  getRange _ = noRange
{- no Range instances for Term, Type, Elm, Tele, Sort, Level, MetaId
  getRange (ValueCmp cmp a u v) = getRange (a,u,v)
  getRange (ElimCmp pol a v es es') = getRange (a,v,es,es')
  getRange (TypeCmp cmp a b) = getRange (a,b)
  getRange (TelCmp a b cmp tel tel') = getRange (a,b,tel,tel')
  getRange (SortCmp cmp s s') = getRange (s,s')
  getRange (LevelCmp cmp l l') = getRange (l,l')
  getRange (UnBlock x) = getRange x
  getRange (Guarded c pid) = getRange c
  getRange (FindInScope x cands) = getRange x
-}

instance Free Constraint where
  freeVars' c =
    case c of
      ValueCmp _ t u v      -> freeVars' (t, (u, v))
      ValueCmpOnFace _ p t u v -> freeVars' (p, (t, (u, v)))
      ElimCmp _ _ t u es es'  -> freeVars' ((t, u), (es, es'))
      TypeCmp _ t t'        -> freeVars' (t, t')
      TelCmp _ _ _ tel tel' -> freeVars' (tel, tel')
      SortCmp _ s s'        -> freeVars' (s, s')
      LevelCmp _ l l'       -> freeVars' (l, l')
      UnBlock _             -> mempty
      Guarded c _           -> freeVars' c
      IsEmpty _ t           -> freeVars' t
      CheckSizeLtSat u      -> freeVars' u
      FindInScope _ _ cs    -> freeVars' cs
      CheckFunDef _ _ _ _   -> mempty
      HasBiggerSort s       -> freeVars' s
      HasPTSRule s1 s2      -> freeVars' (s1 , s2)

instance TermLike Constraint where
  foldTerm f = \case
      ValueCmp _ t u v       -> foldTerm f (t, u, v)
      ValueCmpOnFace _ p t u v -> foldTerm f (p, t, u, v)
      ElimCmp _ _ t u es es' -> foldTerm f (t, u, es, es')
      TypeCmp _ t t'         -> foldTerm f (t, t')
      LevelCmp _ l l'        -> foldTerm f (l, l')
      IsEmpty _ t            -> foldTerm f t
      CheckSizeLtSat u       -> foldTerm f u
      TelCmp _ _ _ tel1 tel2 -> __IMPOSSIBLE__  -- foldTerm f (tel1, tel2) -- Not yet implemented
      SortCmp _ s1 s2        -> __IMPOSSIBLE__  -- foldTerm f (s1, s2) -- Not yet implemented
      UnBlock _              -> __IMPOSSIBLE__  -- mempty     -- Not yet implemented
      Guarded c _            -> __IMPOSSIBLE__  -- foldTerm c -- Not yet implemented
      FindInScope _ _ cs     -> __IMPOSSIBLE__  -- Not yet implemented
      CheckFunDef _ _ _ _    -> __IMPOSSIBLE__  -- Not yet implemented
      HasBiggerSort _        -> __IMPOSSIBLE__  -- Not yet implemented
      HasPTSRule _ _         -> __IMPOSSIBLE__  -- Not yet implemented
  traverseTermM f c = __IMPOSSIBLE__ -- Not yet implemented


data Comparison = CmpEq | CmpLeq
  deriving (Eq, Data, Show)

instance Pretty Comparison where
  pretty CmpEq  = text "="
  pretty CmpLeq = text "=<"

-- | An extension of 'Comparison' to @>=@.
data CompareDirection = DirEq | DirLeq | DirGeq
  deriving (Eq, Show)

instance Pretty CompareDirection where
  pretty = text . \case
    DirEq  -> "="
    DirLeq -> "=<"
    DirGeq -> ">="

-- | Embed 'Comparison' into 'CompareDirection'.
fromCmp :: Comparison -> CompareDirection
fromCmp CmpEq  = DirEq
fromCmp CmpLeq = DirLeq

-- | Flip the direction of comparison.
flipCmp :: CompareDirection -> CompareDirection
flipCmp DirEq  = DirEq
flipCmp DirLeq = DirGeq
flipCmp DirGeq = DirLeq

-- | Turn a 'Comparison' function into a 'CompareDirection' function.
--
--   Property: @dirToCmp f (fromCmp cmp) = f cmp@
dirToCmp :: (Comparison -> a -> a -> c) -> CompareDirection -> a -> a -> c
dirToCmp cont DirEq  = cont CmpEq
dirToCmp cont DirLeq = cont CmpLeq
dirToCmp cont DirGeq = flip $ cont CmpLeq

---------------------------------------------------------------------------
-- * Open things
---------------------------------------------------------------------------

-- | A thing tagged with the context it came from.
data Open a = OpenThing { openThingCheckpoint :: CheckpointId, openThing :: a }
    deriving (Data, Show, Functor, Foldable, Traversable)

instance Decoration Open where
  traverseF f (OpenThing cp x) = OpenThing cp <$> f x

---------------------------------------------------------------------------
-- * Judgements
--
-- Used exclusively for typing of meta variables.
---------------------------------------------------------------------------

-- | Parametrized since it is used without MetaId when creating a new meta.
data Judgement a
  = HasType { jMetaId :: a, jMetaType :: Type }
  | IsSort  { jMetaId :: a, jMetaType :: Type } -- Andreas, 2011-04-26: type needed for higher-order sort metas

instance Show a => Show (Judgement a) where
    show (HasType a t) = show a ++ " : " ++ show t
    show (IsSort  a t) = show a ++ " :sort " ++ show t

-----------------------------------------------------------------------------
-- ** Generalizable variables
-----------------------------------------------------------------------------

data DoGeneralize = YesGeneralize | NoGeneralize
  deriving (Eq, Ord, Show, Data)

-- | The value of a generalizable variable. This is created to be a
--   generalizable meta before checking the type to be generalized.
data GeneralizedValue = GeneralizedValue
  { genvalCheckpoint :: CheckpointId
  , genvalTerm       :: Term
  , genvalType       :: Type
  } deriving (Show, Data)

---------------------------------------------------------------------------
-- ** Meta variables
---------------------------------------------------------------------------

data MetaVariable =
        MetaVar { mvInfo          :: MetaInfo
                , mvPriority      :: MetaPriority -- ^ some metavariables are more eager to be instantiated
                , mvPermutation   :: Permutation
                  -- ^ a metavariable doesn't have to depend on all variables
                  --   in the context, this "permutation" will throw away the
                  --   ones it does not depend on
                , mvJudgement     :: Judgement MetaId
                , mvInstantiation :: MetaInstantiation
                , mvListeners     :: Set Listener -- ^ meta variables scheduled for eta-expansion but blocked by this one
                , mvFrozen        :: Frozen -- ^ are we past the point where we can instantiate this meta variable?
                }

data Listener = EtaExpand MetaId
              | CheckConstraint Nat ProblemConstraint

instance Eq Listener where
  EtaExpand       x   == EtaExpand       y   = x == y
  CheckConstraint x _ == CheckConstraint y _ = x == y
  _ == _ = False

instance Ord Listener where
  EtaExpand       x   `compare` EtaExpand       y   = x `compare` y
  CheckConstraint x _ `compare` CheckConstraint y _ = x `compare` y
  EtaExpand{} `compare` CheckConstraint{} = LT
  CheckConstraint{} `compare` EtaExpand{} = GT

-- | Frozen meta variable cannot be instantiated by unification.
--   This serves to prevent the completion of a definition by its use
--   outside of the current block.
--   (See issues 118, 288, 399).
data Frozen
  = Frozen        -- ^ Do not instantiate.
  | Instantiable
    deriving (Eq, Show)

data MetaInstantiation
        = InstV [Arg String] Term -- ^ solved by term (abstracted over some free variables)
        | Open               -- ^ unsolved
        | OpenIFS            -- ^ open, to be instantiated as "implicit from scope"
        | BlockedConst Term  -- ^ solution blocked by unsolved constraints
        | PostponedTypeCheckingProblem (Closure TypeCheckingProblem) (TCM Bool)

-- | Solving a 'CheckArgs' constraint may or may not check the target type. If
--   it did, it returns a handle to any unsolved constraints.
data CheckedTarget = CheckedTarget (Maybe ProblemId)
                   | NotCheckedTarget

data TypeCheckingProblem
  = CheckExpr Comparison A.Expr Type
  | CheckArgs ExpandHidden Range [NamedArg A.Expr] Type Type (Elims -> Type -> CheckedTarget -> TCM Term)
  | CheckLambda Comparison (Arg ([WithHiding Name], Maybe Type)) A.Expr Type
    -- ^ @(λ (xs : t₀) → e) : t@
    --   This is not an instance of 'CheckExpr' as the domain type
    --   has already been checked.
    --   For example, when checking
    --     @(λ (x y : Fin _) → e) : (x : Fin n) → ?@
    --   we want to postpone @(λ (y : Fin n) → e) : ?@ where @Fin n@
    --   is a 'Type' rather than an 'A.Expr'.
  | UnquoteTactic Term Term Type   -- ^ First argument is computation and the others are hole and goal type

instance Show MetaInstantiation where
  show (InstV tel t) = "InstV " ++ show tel ++ " (" ++ show t ++ ")"
  show Open      = "Open"
  show OpenIFS   = "OpenIFS"
  show (BlockedConst t) = "BlockedConst (" ++ show t ++ ")"
  show (PostponedTypeCheckingProblem{}) = "PostponedTypeCheckingProblem (...)"

-- | Meta variable priority:
--   When we have an equation between meta-variables, which one
--   should be instantiated?
--
--   Higher value means higher priority to be instantiated.
newtype MetaPriority = MetaPriority Int
    deriving (Eq , Ord , Show)

data RunMetaOccursCheck
  = RunMetaOccursCheck
  | DontRunMetaOccursCheck
  deriving (Eq , Ord , Show)

-- | @MetaInfo@ is cloned from one meta to the next during pruning.
data MetaInfo = MetaInfo
  { miClosRange       :: Closure Range -- TODO: Not so nice. But we want both to have the environment of the meta (Closure) and its range.
--  , miRelevance       :: Relevance          -- ^ Created in irrelevant position?
  , miMetaOccursCheck :: RunMetaOccursCheck -- ^ Run the extended occurs check that goes in definitions?
  , miNameSuggestion  :: MetaNameSuggestion
    -- ^ Used for printing.
    --   @Just x@ if meta-variable comes from omitted argument with name @x@.
  , miGeneralizable   :: Arg DoGeneralize
    -- ^ Should this meta be generalized if unsolved? If so, at what ArgInfo?
  }

-- | Name suggestion for meta variable.  Empty string means no suggestion.
type MetaNameSuggestion = String

-- | For printing, we couple a meta with its name suggestion.
data NamedMeta = NamedMeta
  { nmSuggestion :: MetaNameSuggestion
  , nmid         :: MetaId
  }

instance Pretty NamedMeta where
  pretty (NamedMeta "" x) = pretty x
  pretty (NamedMeta "_" x) = pretty x
  pretty (NamedMeta s  x) = text $ "_" ++ s ++ prettyShow x

type MetaStore = Map MetaId MetaVariable

instance HasRange MetaInfo where
  getRange = clValue . miClosRange

instance HasRange MetaVariable where
    getRange m = getRange $ getMetaInfo m

instance SetRange MetaInfo where
  setRange r m = m { miClosRange = (miClosRange m) { clValue = r }}

instance SetRange MetaVariable where
  setRange r m = m { mvInfo = setRange r (mvInfo m) }

normalMetaPriority :: MetaPriority
normalMetaPriority = MetaPriority 0

lowMetaPriority :: MetaPriority
lowMetaPriority = MetaPriority (-10)

highMetaPriority :: MetaPriority
highMetaPriority = MetaPriority 10

getMetaInfo :: MetaVariable -> Closure Range
getMetaInfo = miClosRange . mvInfo

getMetaScope :: MetaVariable -> ScopeInfo
getMetaScope m = clScope $ getMetaInfo m

getMetaEnv :: MetaVariable -> TCEnv
getMetaEnv m = clEnv $ getMetaInfo m

getMetaSig :: MetaVariable -> Signature
getMetaSig m = clSignature $ getMetaInfo m

getMetaRelevance :: MetaVariable -> Relevance
getMetaRelevance = envRelevance . getMetaEnv

---------------------------------------------------------------------------
-- ** Interaction meta variables
---------------------------------------------------------------------------

-- | Interaction points are created by the scope checker who sets the range.
--   The meta variable is created by the type checker and then hooked up to the
--   interaction point.
data InteractionPoint = InteractionPoint
  { ipRange :: Range        -- ^ The position of the interaction point.
  , ipMeta  :: Maybe MetaId -- ^ The meta variable, if any, holding the type etc.
  , ipSolved:: Bool         -- ^ Has this interaction point already been solved?
  , ipClause:: IPClause
      -- ^ The clause of the interaction point (if any).
      --   Used for case splitting.
  }

instance Eq InteractionPoint where (==) = (==) `on` ipMeta

-- | Data structure managing the interaction points.
--
--   We never remove interaction points from this map, only set their
--   'ipSolved' to @True@.  (Issue #2368)
type InteractionPoints = Map InteractionId InteractionPoint

-- | Which clause is an interaction point located in?
data IPClause = IPClause
  { ipcQName    :: QName  -- ^ The name of the function.
  , ipcClauseNo :: Int    -- ^ The number of the clause of this function.
  , ipcClause   :: A.RHS  -- ^ The original AST clause rhs.
  }
  | IPNoClause -- ^ The interaction point is not in the rhs of a clause.
  deriving Data

instance Eq IPClause where
  IPNoClause     == IPNoClause       = True
  IPClause x i _ == IPClause x' i' _ = x == x' && i == i'
  _              == _                = False

---------------------------------------------------------------------------
-- ** Signature
---------------------------------------------------------------------------

data Signature = Sig
      { _sigSections    :: Sections
      , _sigDefinitions :: Definitions
      , _sigRewriteRules:: RewriteRuleMap  -- ^ The rewrite rules defined in this file.
      }
  deriving (Data, Show)

sigSections :: Lens' Sections Signature
sigSections f s =
  f (_sigSections s) <&>
  \x -> s {_sigSections = x}

sigDefinitions :: Lens' Definitions Signature
sigDefinitions f s =
  f (_sigDefinitions s) <&>
  \x -> s {_sigDefinitions = x}

sigRewriteRules :: Lens' RewriteRuleMap Signature
sigRewriteRules f s =
  f (_sigRewriteRules s) <&>
  \x -> s {_sigRewriteRules = x}

type Sections    = Map ModuleName Section
type Definitions = HashMap QName Definition
type RewriteRuleMap = HashMap QName RewriteRules
type DisplayForms = HashMap QName [LocalDisplayForm]

newtype Section = Section { _secTelescope :: Telescope }
  deriving (Data, Show)

instance Pretty Section where
  pretty = pretty . _secTelescope

secTelescope :: Lens' Telescope Section
secTelescope f s =
  f (_secTelescope s) <&>
  \x -> s {_secTelescope = x}

emptySignature :: Signature
emptySignature = Sig Map.empty HMap.empty HMap.empty

-- | A @DisplayForm@ is in essence a rewrite rule
--   @
--      q ts --> dt
--   @
--   for a defined symbol (could be a constructor as well) @q@.
--   The right hand side is a 'DisplayTerm' which is used to
--   'reify' to a more readable 'Abstract.Syntax'.
--
--   The patterns @ts@ are just terms, but @var 0@ is interpreted
--   as a hole.  Each occurrence of @var 0@ is a new hole (pattern var).
--   For each *occurrence* of @var0@ the rhs @dt@ has a free variable.
--   These are instantiated when matching a display form against a
--   term @q vs@ succeeds.
data DisplayForm = Display
  { dfFreeVars :: Nat
    -- ^ Number @n@ of free variables in 'dfRHS'.
  , dfPats     :: Elims
    -- ^ Left hand side patterns, where @var 0@ stands for a pattern
    --   variable.  There should be @n@ occurrences of @var0@ in
    --   'dfPats'.
    --   The 'ArgInfo' is ignored in these patterns.
  , dfRHS      :: DisplayTerm
    -- ^ Right hand side, with @n@ free variables.
  }
  deriving (Data, Show)

type LocalDisplayForm = Open DisplayForm

-- | A structured presentation of a 'Term' for reification into
--   'Abstract.Syntax'.
data DisplayTerm
  = DWithApp DisplayTerm [DisplayTerm] Elims
    -- ^ @(f vs | ws) es@.
    --   The first 'DisplayTerm' is the parent function @f@ with its args @vs@.
    --   The list of 'DisplayTerm's are the with expressions @ws@.
    --   The 'Elims' are additional arguments @es@
    --   (possible in case the with-application is of function type)
    --   or projections (if it is of record type).
  | DCon ConHead ConInfo [Arg DisplayTerm]
    -- ^ @c vs@.
  | DDef QName [Elim' DisplayTerm]
    -- ^ @d vs@.
  | DDot Term
    -- ^ @.v@.
  | DTerm Term
    -- ^ @v@.
  deriving (Data, Show)

instance Free DisplayForm where
  freeVars' (Display n ps t) = bind (freeVars' ps) `mappend` bind' n (freeVars' t)

instance Free DisplayTerm where
  freeVars' (DWithApp t ws es) = freeVars' (t, (ws, es))
  freeVars' (DCon _ _ vs)      = freeVars' vs
  freeVars' (DDef _ es)        = freeVars' es
  freeVars' (DDot v)           = freeVars' v
  freeVars' (DTerm v)          = freeVars' v

instance Pretty DisplayTerm where
  prettyPrec p v =
    case v of
      DTerm v          -> prettyPrec p v
      DDot v           -> text "." P.<> prettyPrec 10 v
      DDef f es        -> pretty f `pApp` es
      DCon c _ vs      -> pretty (conName c) `pApp` map Apply vs
      DWithApp h ws es ->
        mparens (p > 0)
          (sep [ pretty h
              , nest 2 $ fsep [ text "|" <+> pretty w | w <- ws ] ])
        `pApp` es
    where
      pApp d els = mparens (not (null els) && p > 9) $
                   sep [d, nest 2 $ fsep (map (prettyPrec 10) els)]

-- | By default, we have no display form.
defaultDisplayForm :: QName -> [LocalDisplayForm]
defaultDisplayForm c = []

defRelevance :: Definition -> Relevance
defRelevance = getRelevance . defArgInfo

-- | Non-linear (non-constructor) first-order pattern.
data NLPat
  = PVar !Int [Arg Int]
    -- ^ Matches anything (modulo non-linearity) that only contains bound
    --   variables that occur in the given arguments.
  | PWild
    -- ^ Matches anything (e.g. irrelevant terms).
  | PDef QName PElims
    -- ^ Matches @f es@
  | PLam ArgInfo (Abs NLPat)
    -- ^ Matches @λ x → t@
  | PPi (Dom NLPType) (Abs NLPType)
    -- ^ Matches @(x : A) → B@
  | PBoundVar {-# UNPACK #-} !Int PElims
    -- ^ Matches @x es@ where x is a lambda-bound variable
  | PTerm Term
    -- ^ Matches the term modulo β (ideally βη).
  deriving (Data, Show)
type PElims = [Elim' NLPat]

data NLPType = NLPType
  { nlpTypeLevel :: NLPat  -- always PWild or PVar (with all bound variables in scope)
  , nlpTypeUnEl  :: NLPat
  } deriving (Data, Show)

type RewriteRules = [RewriteRule]

-- | Rewrite rules can be added independently from function clauses.
data RewriteRule = RewriteRule
  { rewName    :: QName      -- ^ Name of rewrite rule @q : Γ → f ps ≡ rhs@
                             --   where @≡@ is the rewrite relation.
  , rewContext :: Telescope  -- ^ @Γ@.
  , rewHead    :: QName      -- ^ @f@.
  , rewPats    :: PElims     -- ^ @Γ ⊢ f ps : t@.
  , rewRHS     :: Term       -- ^ @Γ ⊢ rhs : t@.
  , rewType    :: Type       -- ^ @Γ ⊢ t@.
  }
    deriving (Data, Show)

data Definition = Defn
  { defArgInfo        :: ArgInfo -- ^ Hiding should not be used.
  , defName           :: QName
  , defType           :: Type    -- ^ Type of the lifted definition.
  , defPolarity       :: [Polarity]
    -- ^ Variance information on arguments of the definition.
    --   Does not include info for dropped parameters to
    --   projection(-like) functions and constructors.
  , defArgOccurrences :: [Occurrence]
    -- ^ Positivity information on arguments of the definition.
    --   Does not include info for dropped parameters to
    --   projection(-like) functions and constructors.

    --   Sometimes Agda looks up 'Occurrence's in these lists based on
    --   their position, so one might consider replacing the list
    --   with, say, an 'IntMap'. However, presumably these lists tend
    --   to be short, in which case 'IntMap's could be slower than
    --   lists. For instance, at one point the longest list
    --   encountered for the standard library (in serialised
    --   interfaces) had length 27. Distribution:
    --
    --   Length, number of lists
    --   -----------------------
    --
    --    0, 2444
    --    1,  721
    --    2,  433
    --    3,  668
    --    4,  602
    --    5,  624
    --    6,  626
    --    7,  484
    --    8,  375
    --    9,  264
    --   10,  305
    --   11,  188
    --   12,  171
    --   13,  108
    --   14,   84
    --   15,   80
    --   16,   38
    --   17,   23
    --   18,   16
    --   19,    8
    --   20,    7
    --   21,    5
    --   22,    2
    --   23,    3
    --   27,    1

  , defArgGeneralizable :: [DoGeneralize]
    -- ^ Metas created when checking an argument inherit the argument's 'DoGeneralize' flag.
  , defDisplay        :: [LocalDisplayForm]
  , defMutual         :: MutualId
  , defCompiledRep    :: CompiledRepresentation
  , defInstance       :: Maybe QName
    -- ^ @Just q@ when this definition is an instance of class q
  , defCopy           :: Bool
    -- ^ Has this function been created by a module
                         -- instantiation?
  , defMatchable      :: Bool
    -- ^ Is the def matched against in a rewrite rule?
  , defNoCompilation  :: Bool
    -- ^ should compilers skip this? Used for e.g. cubical's comp
  , defInjective      :: Bool
    -- ^ Should the def be treated as injective by the pattern matching unifier?
  , theDef            :: Defn
  }
    deriving (Data, Show)

theDefLens :: Lens' Defn Definition
theDefLens f d = f (theDef d) <&> \ df -> d { theDef = df }

-- | Create a definition with sensible defaults.
defaultDefn :: ArgInfo -> QName -> Type -> Defn -> Definition
defaultDefn info x t def = Defn
  { defArgInfo        = info
  , defName           = x
  , defType           = t
  , defPolarity       = []
  , defArgOccurrences = []
  , defArgGeneralizable = []
  , defDisplay        = defaultDisplayForm x
  , defMutual         = 0
  , defCompiledRep    = noCompiledRep
  , defInstance       = Nothing
  , defCopy           = False
  , defMatchable      = False
  , defNoCompilation  = False
  , defInjective      = False
  , theDef            = def
  }

-- | Polarity for equality and subtype checking.
data Polarity
  = Covariant      -- ^ monotone
  | Contravariant  -- ^ antitone
  | Invariant      -- ^ no information (mixed variance)
  | Nonvariant     -- ^ constant
  deriving (Data, Show, Eq)

instance Pretty Polarity where
  pretty = text . \case
    Covariant     -> "+"
    Contravariant -> "-"
    Invariant     -> "*"
    Nonvariant    -> "_"

-- | Information about whether an argument is forced by the type of a function.
data IsForced
  = Forced
  | NotForced
  deriving (Data, Show, Eq)

-- | The backends are responsible for parsing their own pragmas.
data CompilerPragma = CompilerPragma Range String
  deriving (Data, Show, Eq)

instance HasRange CompilerPragma where
  getRange (CompilerPragma r _) = r

type BackendName    = String

-- Temporary: while we still parse the old pragmas we need to know the names of
-- the corresponding backends.
jsBackendName, ghcBackendName, uhcBackendName :: BackendName
jsBackendName  = "JS"
ghcBackendName = "GHC"
uhcBackendName = "UHC"

type CompiledRepresentation = Map BackendName [CompilerPragma]

noCompiledRep :: CompiledRepresentation
noCompiledRep = Map.empty

-- A face represented as a list of equality constraints.
-- (r,False) ↦ (r = i0)
-- (r,True ) ↦ (r = i1)
type Face = [(Term,Bool)]

-- | An alternative representation of partial elements in a telescope:
--   Γ ⊢ λ Δ. [φ₁ u₁, ... , φₙ uₙ] : Δ → PartialP (∨_ᵢ φᵢ) T
--   see cubicaltt paper (however we do not store the type T).
data System = System
  { systemTel :: Telescope
    -- ^ the telescope Δ, binding vars for the clauses, Γ ⊢ Δ
  , systemClauses :: [(Face,Term)]
    -- ^ a system [φ₁ u₁, ... , φₙ uₙ] where Γ, Δ ⊢ φᵢ and Γ, Δ, φᵢ ⊢ uᵢ
  } deriving (Data, Show)

-- | Additional information for extended lambdas.
data ExtLamInfo = ExtLamInfo
  { extLamModule    :: ModuleName
    -- ^ For complicated reasons the scope checker decides the QName of a
    --   pattern lambda, and thus its module. We really need to decide the
    --   module during type checking though, since if the lambda appears in a
    --   refined context the module picked by the scope checker has very much
    --   the wrong parameters.
  , extLamSys :: !(Maybe System)
  } deriving (Data, Show)

modifySystem :: (System -> System) -> ExtLamInfo -> ExtLamInfo
modifySystem f e = let !e' = e { extLamSys = f <$> extLamSys e } in e'

-- | Additional information for projection 'Function's.
data Projection = Projection
  { projProper    :: Maybe QName
    -- ^ @Nothing@ if only projection-like, @Just r@ if record projection.
    --   The @r@ is the name of the record type projected from.
    --   This field is updated by module application.
  , projOrig      :: QName
    -- ^ The original projection name
    --   (current name could be from module application).
  , projFromType  :: Arg QName
    -- ^ Type projected from. Original record type if @projProper = Just{}@.
    --   Also stores @ArgInfo@ of the principal argument.
    --   This field is unchanged by module application.
  , projIndex     :: Int
    -- ^ Index of the record argument.
    --   Start counting with 1, because 0 means that
    --   it is already applied to the record value.
    --   This can happen in module instantiation, but
    --   then either the record value is @var 0@, or @funProjection == Nothing@.
  , projLams :: ProjLams
    -- ^ Term @t@ to be be applied to record parameters and record value.
    --   The parameters will be dropped.
    --   In case of a proper projection, a postfix projection application
    --   will be created: @t = \ pars r -> r .p@
    --   (Invariant: the number of abstractions equals 'projIndex'.)
    --   In case of a projection-like function, just the function symbol
    --   is returned as 'Def':  @t = \ pars -> f@.
  } deriving (Data, Show)

-- | Abstractions to build projection function (dropping parameters).
newtype ProjLams = ProjLams { getProjLams :: [Arg ArgName] }
  deriving (Data, Show, Null)

-- | Building the projection function (which drops the parameters).
projDropPars :: Projection -> ProjOrigin -> Term
-- Proper projections:
projDropPars (Projection Just{} d _ _ lams) o =
  case initLast $ getProjLams lams of
    Nothing -> Def d []
    Just (pars, Arg i y) ->
      let core = Lam i $ Abs y $ Var 0 [Proj o d] in
      List.foldr (\ (Arg ai x) -> Lam ai . NoAbs x) core pars
-- Projection-like functions:
projDropPars (Projection Nothing _ _ _ lams) o | null lams = __IMPOSSIBLE__
projDropPars (Projection Nothing d _ _ lams) o =
  List.foldr (\ (Arg ai x) -> Lam ai . NoAbs x) (Def d []) $ init $ getProjLams lams

-- | The info of the principal (record) argument.
projArgInfo :: Projection -> ArgInfo
projArgInfo (Projection _ _ _ _ lams) =
  maybe __IMPOSSIBLE__ getArgInfo $ lastMaybe $ getProjLams lams

-- | Should a record type admit eta-equality?
data EtaEquality
  = Specified { theEtaEquality :: !HasEta }  -- ^ User specifed 'eta-equality' or 'no-eta-equality'.
  | Inferred  { theEtaEquality :: !HasEta }  -- ^ Positivity checker inferred whether eta is safe.
  deriving (Data, Show, Eq)

-- | Make sure we do not overwrite a user specification.
setEtaEquality :: EtaEquality -> HasEta -> EtaEquality
setEtaEquality e@Specified{} _ = e
setEtaEquality _ b = Inferred b

data FunctionFlag
  = FunStatic  -- ^ Should calls to this function be normalised at compile-time?
  | FunInline  -- ^ Should calls to this function be inlined by the compiler?
  | FunMacro   -- ^ Is this function a macro?
  deriving (Data, Eq, Ord, Enum, Show)

data Defn = Axiom -- ^ Postulate
          | GeneralizableVar -- ^ Generalizable variable (introduced in `generalize` block)
          | AbstractDefn Defn
            -- ^ Returned by 'getConstInfo' if definition is abstract.
          | Function
            { funClauses        :: [Clause]
            , funCompiled       :: Maybe CompiledClauses
              -- ^ 'Nothing' while function is still type-checked.
              --   @Just cc@ after type and coverage checking and
              --   translation to case trees.
            , funTreeless       :: Maybe Compiled
              -- ^ Intermediate representation for compiler backends.
            , funInv            :: FunctionInverse
            , funMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this function.
              --   Empty list if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , funAbstr          :: IsAbstract
            , funDelayed        :: Delayed
              -- ^ Are the clauses of this definition delayed?
            , funProjection     :: Maybe Projection
              -- ^ Is it a record projection?
              --   If yes, then return the name of the record type and index of
              --   the record argument.  Start counting with 1, because 0 means that
              --   it is already applied to the record. (Can happen in module
              --   instantiation.) This information is used in the termination
              --   checker.
            , funFlags          :: Set FunctionFlag
            , funTerminates     :: Maybe Bool
              -- ^ Has this function been termination checked?  Did it pass?
            , funExtLam         :: Maybe ExtLamInfo
              -- ^ Is this function generated from an extended lambda?
              --   If yes, then return the number of hidden and non-hidden lambda-lifted arguments
            , funWith           :: Maybe QName
              -- ^ Is this a generated with-function? If yes, then what's the
              --   name of the parent function.
            , funCopatternLHS   :: Bool
              -- ^ Is this a function defined by copatterns?
            }
          | Datatype
            { dataPars           :: Nat            -- ^ Number of parameters.
            , dataIxs            :: Nat            -- ^ Number of indices.
            , dataInduction      :: Induction      -- ^ @data@ or @codata@ (legacy).
            , dataClause         :: (Maybe Clause) -- ^ This might be in an instantiated module.
            , dataCons           :: [QName]        -- ^ Constructor names.
            , dataSort           :: Sort
            , dataMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this data type.
              --   Empty if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , dataAbstr          :: IsAbstract
            }
          | Record
            { recPars           :: Nat
              -- ^ Number of parameters.
            , recClause         :: Maybe Clause
              -- ^ Was this record type created by a module application?
              --   If yes, the clause is its definition (linking back to the original record type).
            , recConHead        :: ConHead
              -- ^ Constructor name and fields.
            , recNamedCon       :: Bool
              -- ^ Does this record have a @constructor@?
            , recFields         :: [Arg QName]
              -- ^ The record field names.
            , recTel            :: Telescope
              -- ^ The record field telescope. (Includes record parameters.)
              --   Note: @TelV recTel _ == telView' recConType@.
              --   Thus, @recTel@ is redundant.
            , recMutual         :: Maybe [QName]
              -- ^ Mutually recursive functions, @data@s and @record@s.
              --   Does include this record.
              --   Empty if not recursive.
              --   @Nothing@ if not yet computed (by positivity checker).
            , recEtaEquality'    :: EtaEquality
              -- ^ Eta-expand at this record type?
              --   @False@ for unguarded recursive records and coinductive records
              --   unless the user specifies otherwise.
            , recInduction      :: Maybe Induction
              -- ^ 'Inductive' or 'CoInductive'?  Matters only for recursive records.
              --   'Nothing' means that the user did not specify it, which is an error
              --   for recursive records.
            , recAbstr          :: IsAbstract
            , recComp           :: Maybe QName
            }
          | Constructor
            { conPars   :: Int         -- ^ Number of parameters.
            , conArity  :: Int         -- ^ Number of arguments (excluding parameters).
            , conSrcCon :: ConHead     -- ^ Name of (original) constructor and fields. (This might be in a module instance.)
            , conData   :: QName       -- ^ Name of datatype or record type.
            , conAbstr  :: IsAbstract
            , conInd    :: Induction   -- ^ Inductive or coinductive?
            , conComp   :: Maybe (QName,[QName]) -- ^ (cubical composition, projections)
            , conForced :: [IsForced]  -- ^ Which arguments are forced (i.e. determined by the type of the constructor)?
            , conErased :: [Bool]      -- ^ Which arguments are erased at runtime (computed during compilation to treeless)
            }
          | Primitive
            { primAbstr :: IsAbstract
            , primName  :: String
            , primClauses :: [Clause]
              -- ^ 'null' for primitive functions, @not null@ for builtin functions.
            , primInv      :: FunctionInverse
              -- ^ Builtin functions can have inverses. For instance, natural number addition.
            , primCompiled :: Maybe CompiledClauses
              -- ^ 'Nothing' for primitive functions,
              --   @'Just' something@ for builtin functions.
            }
            -- ^ Primitive or builtin functions.
    deriving (Data, Show)

instance Pretty Definition where
  pretty Defn{..} =
    text "Defn {" <?> vcat
      [ text "defArgInfo        =" <?> pshow defArgInfo
      , text "defName           =" <?> pretty defName
      , text "defType           =" <?> pretty defType
      , text "defPolarity       =" <?> pshow defPolarity
      , text "defArgOccurrences =" <?> pshow defArgOccurrences
      , text "defDisplay        =" <?> pshow defDisplay -- TODO: pretty DisplayForm
      , text "defMutual         =" <?> pshow defMutual
      , text "defCompiledRep    =" <?> pshow defCompiledRep
      , text "defInstance       =" <?> pshow defInstance
      , text "defCopy           =" <?> pshow defCopy
      , text "defMatchable      =" <?> pshow defMatchable
      , text "defInjective      =" <?> pshow defInjective
      , text "theDef            =" <?> pretty theDef ] <+> text "}"

instance Pretty Defn where
  pretty Axiom = text "Axiom"
  pretty GeneralizableVar{} = text "GeneralizableVar"
  pretty (AbstractDefn def) = text "AbstractDefn" <?> parens (pretty def)
  pretty Function{..} =
    text "Function {" <?> vcat
      [ text "funClauses      =" <?> vcat (map pretty funClauses)
      , text "funCompiled     =" <?> pshow funCompiled
      , text "funTreeless     =" <?> pshow funTreeless
      , text "funInv          =" <?> pshow funInv
      , text "funMutual       =" <?> pshow funMutual
      , text "funAbstr        =" <?> pshow funAbstr
      , text "funDelayed      =" <?> pshow funDelayed
      , text "funProjection   =" <?> pshow funProjection
      , text "funFlags        =" <?> pshow funFlags
      , text "funTerminates   =" <?> pshow funTerminates
      , text "funWith         =" <?> pshow funWith
      , text "funCopatternLHS =" <?> pshow funCopatternLHS ] <?> text "}"
  pretty Datatype{..} =
    text "Datatype {" <?> vcat
      [ text "dataPars       =" <?> pshow dataPars
      , text "dataIxs        =" <?> pshow dataIxs
      , text "dataInduction  =" <?> pshow dataInduction
      , text "dataClause     =" <?> pretty dataClause
      , text "dataCons       =" <?> pshow dataCons
      , text "dataSort       =" <?> pretty dataSort
      , text "dataMutual     =" <?> pshow dataMutual
      , text "dataAbstr      =" <?> pshow dataAbstr ] <?> text "}"
  pretty Record{..} =
    text "Record {" <?> vcat
      [ text "recPars         =" <?> pshow recPars
      , text "recClause       =" <?> pretty recClause
      , text "recConHead      =" <?> pshow recConHead
      , text "recNamedCon     =" <?> pshow recNamedCon
      , text "recFields       =" <?> pshow recFields
      , text "recTel          =" <?> pretty recTel
      , text "recMutual       =" <?> pshow recMutual
      , text "recEtaEquality' =" <?> pshow recEtaEquality'
      , text "recInduction    =" <?> pshow recInduction
      , text "recAbstr        =" <?> pshow recAbstr ] <?> text "}"
  pretty Constructor{..} =
    text "Constructor {" <?> vcat
      [ text "conPars   =" <?> pshow conPars
      , text "conArity  =" <?> pshow conArity
      , text "conSrcCon =" <?> pshow conSrcCon
      , text "conData   =" <?> pshow conData
      , text "conAbstr  =" <?> pshow conAbstr
      , text "conInd    =" <?> pshow conInd
      , text "conErased =" <?> pshow conErased ] <?> text "}"
  pretty Primitive{..} =
    text "Primitive {" <?> vcat
      [ text "primAbstr    =" <?> pshow primAbstr
      , text "primName     =" <?> pshow primName
      , text "primClauses  =" <?> pshow primClauses
      , text "primCompiled =" <?> pshow primCompiled ] <?> text "}"


-- | Is the record type recursive?
recRecursive :: Defn -> Bool
recRecursive (Record { recMutual = Just qs }) = not $ null qs
recRecursive _ = __IMPOSSIBLE__

recEtaEquality :: Defn -> HasEta
recEtaEquality = theEtaEquality . recEtaEquality'

-- | A template for creating 'Function' definitions, with sensible defaults.
emptyFunction :: Defn
emptyFunction = Function
  { funClauses     = []
  , funCompiled    = Nothing
  , funTreeless    = Nothing
  , funInv         = NotInjective
  , funMutual      = Nothing
  , funAbstr       = ConcreteDef
  , funDelayed     = NotDelayed
  , funProjection  = Nothing
  , funFlags       = Set.empty
  , funTerminates  = Nothing
  , funExtLam      = Nothing
  , funWith        = Nothing
  , funCopatternLHS = False
  }

funFlag :: FunctionFlag -> Lens' Bool Defn
funFlag flag f def@Function{ funFlags = flags } =
  f (Set.member flag flags) <&>
  \ b -> def{ funFlags = (if b then Set.insert else Set.delete) flag flags }
funFlag _ f def = f False <&> const def

funStatic, funInline, funMacro :: Lens' Bool Defn
funStatic       = funFlag FunStatic
funInline       = funFlag FunInline
funMacro        = funFlag FunMacro

isMacro :: Defn -> Bool
isMacro = (^. funMacro)

-- | Checking whether we are dealing with a function yet to be defined.
isEmptyFunction :: Defn -> Bool
isEmptyFunction def =
  case def of
    Function { funClauses = [] } -> True
    _ -> False

isCopatternLHS :: [Clause] -> Bool
isCopatternLHS = List.any (List.any (isJust . A.isProjP) . namedClausePats)

recCon :: Defn -> QName
recCon Record{ recConHead } = conName recConHead
recCon _ = __IMPOSSIBLE__

defIsRecord :: Defn -> Bool
defIsRecord Record{} = True
defIsRecord _        = False

defIsDataOrRecord :: Defn -> Bool
defIsDataOrRecord Record{}   = True
defIsDataOrRecord Datatype{} = True
defIsDataOrRecord _          = False

defConstructors :: Defn -> [QName]
defConstructors Datatype{dataCons = cs} = cs
defConstructors Record{recConHead = c} = [conName c]
defConstructors _ = __IMPOSSIBLE__

newtype Fields = Fields [(C.Name, Type)]
  deriving Null

-- | Did we encounter a simplifying reduction?
--   In terms of CIC, that would be a iota-reduction.
--   In terms of Agda, this is a constructor or literal
--   pattern that matched.
--   Just beta-reduction (substitution) or delta-reduction
--   (unfolding of definitions) does not count as simplifying?

data Simplification = YesSimplification | NoSimplification
  deriving (Data, Eq, Show)

instance Null Simplification where
  empty = NoSimplification
  null  = (== NoSimplification)

instance Semigroup Simplification where
  YesSimplification <> _ = YesSimplification
  NoSimplification  <> s = s

instance Monoid Simplification where
  mempty = NoSimplification
  mappend = (<>)

data Reduced no yes = NoReduction no | YesReduction Simplification yes
    deriving Functor

-- | Three cases: 1. not reduced, 2. reduced, but blocked, 3. reduced, not blocked.
data IsReduced
  = NotReduced
  | Reduced    (Blocked ())

data MaybeReduced a = MaybeRed
  { isReduced     :: IsReduced
  , ignoreReduced :: a
  }
  deriving (Functor)

instance IsProjElim e => IsProjElim (MaybeReduced e) where
  isProjElim = isProjElim . ignoreReduced

type MaybeReducedArgs = [MaybeReduced (Arg Term)]
type MaybeReducedElims = [MaybeReduced Elim]

notReduced :: a -> MaybeReduced a
notReduced x = MaybeRed NotReduced x

reduced :: Blocked (Arg Term) -> MaybeReduced (Arg Term)
reduced b = case b of
  NotBlocked _ (Arg _ (MetaV x _)) -> MaybeRed (Reduced $ Blocked x ()) v
  _                                -> MaybeRed (Reduced $ () <$ b)      v
  where
    v = ignoreBlocking b

-- | Controlling 'reduce'.
data AllowedReduction
  = ProjectionReductions     -- ^ (Projection and) projection-like functions may be reduced.
  | InlineReductions         -- ^ Functions marked INLINE may be reduced.
  | CopatternReductions      -- ^ Copattern definitions may be reduced.
  | FunctionReductions       -- ^ Non-recursive functions and primitives may be reduced.
  | RecursiveReductions      -- ^ Even recursive functions may be reduced.
  | LevelReductions          -- ^ Reduce @'Level'@ terms.
  | UnconfirmedReductions    -- ^ Functions whose termination has not (yet) been confirmed.
  | NonTerminatingReductions -- ^ Functions that have failed termination checking.
  deriving (Show, Eq, Ord, Enum, Bounded, Data)

type AllowedReductions = [AllowedReduction]

-- | Not quite all reductions (skip non-terminating reductions)
allReductions :: AllowedReductions
allReductions = [minBound..pred maxBound]

data PrimFun = PrimFun
        { primFunName           :: QName
        , primFunArity          :: Arity
        , primFunImplementation :: [Arg Term] -> Int -> ReduceM (Reduced MaybeReducedArgs Term)
        }

primFun :: QName -> Arity -> ([Arg Term] -> ReduceM (Reduced MaybeReducedArgs Term)) -> PrimFun
primFun q ar imp = PrimFun q ar (\ args _ -> imp args)

defClauses :: Definition -> [Clause]
defClauses Defn{theDef = Function{funClauses = cs}}        = cs
defClauses Defn{theDef = Primitive{primClauses = cs}}      = cs
defClauses Defn{theDef = Datatype{dataClause = Just c}}    = [c]
defClauses Defn{theDef = Record{recClause = Just c}}       = [c]
defClauses _                                               = []

defCompiled :: Definition -> Maybe CompiledClauses
defCompiled Defn{theDef = Function {funCompiled  = mcc}} = mcc
defCompiled Defn{theDef = Primitive{primCompiled = mcc}} = mcc
defCompiled _ = Nothing

defParameters :: Definition -> Maybe Nat
defParameters Defn{theDef = Datatype{dataPars = n}} = Just n
defParameters Defn{theDef = Record  {recPars  = n}} = Just n
defParameters _                                     = Nothing

defInverse :: Definition -> FunctionInverse
defInverse Defn{theDef = Function { funInv  = inv }} = inv
defInverse Defn{theDef = Primitive{ primInv = inv }} = inv
defInverse _                                         = NotInjective

defCompilerPragmas :: BackendName -> Definition -> [CompilerPragma]
defCompilerPragmas b = reverse . fromMaybe [] . Map.lookup b . defCompiledRep
  -- reversed because we add new pragmas to the front of the list

-- | Are the clauses of this definition delayed?
defDelayed :: Definition -> Delayed
defDelayed Defn{theDef = Function{funDelayed = d}} = d
defDelayed _                                       = NotDelayed

-- | Has the definition failed the termination checker?
defNonterminating :: Definition -> Bool
defNonterminating Defn{theDef = Function{funTerminates = Just False}} = True
defNonterminating _                                                   = False

-- | Has the definition not termination checked or did the check fail?
defTerminationUnconfirmed :: Definition -> Bool
defTerminationUnconfirmed Defn{theDef = Function{funTerminates = Just True}} = False
defTerminationUnconfirmed Defn{theDef = Function{funTerminates = _        }} = True
defTerminationUnconfirmed _ = False

defAbstract :: Definition -> IsAbstract
defAbstract d = case theDef d of
    Axiom{}                   -> ConcreteDef
    GeneralizableVar{}        -> ConcreteDef
    AbstractDefn{}            -> AbstractDef
    Function{funAbstr = a}    -> a
    Datatype{dataAbstr = a}   -> a
    Record{recAbstr = a}      -> a
    Constructor{conAbstr = a} -> a
    Primitive{primAbstr = a}  -> a

defForced :: Definition -> [IsForced]
defForced d = case theDef d of
    Constructor{conForced = fs} -> fs
    Axiom{}                     -> []
    GeneralizableVar{}          -> []
    AbstractDefn{}              -> []
    Function{}                  -> []
    Datatype{}                  -> []
    Record{}                    -> []
    Primitive{}                 -> []

---------------------------------------------------------------------------
-- ** Injectivity
---------------------------------------------------------------------------

type FunctionInverse = FunctionInverse' Clause
type InversionMap c = Map TermHead [c]

data FunctionInverse' c
  = NotInjective
  | Inverse (InversionMap c)
  deriving (Data, Show, Functor)

data TermHead = SortHead
              | PiHead
              | ConsHead QName
              | VarHead Nat
              | UnknownHead
  deriving (Data, Eq, Ord, Show)

instance Pretty TermHead where
  pretty = \ case
    SortHead    -> text "SortHead"
    PiHead      -> text "PiHead"
    ConsHead q  -> text "ConsHead" <+> pretty q
    VarHead i   -> text ("VarHead " ++ show i)
    UnknownHead -> text "UnknownHead"

---------------------------------------------------------------------------
-- ** Mutual blocks
---------------------------------------------------------------------------

newtype MutualId = MutId Int32
  deriving (Data, Eq, Ord, Show, Num, Enum)

---------------------------------------------------------------------------
-- ** Statistics
---------------------------------------------------------------------------

type Statistics = Map String Integer

---------------------------------------------------------------------------
-- ** Trace
---------------------------------------------------------------------------

data Call = CheckClause Type A.SpineClause
          | CheckPattern A.Pattern Telescope Type
          | CheckLetBinding A.LetBinding
          | InferExpr A.Expr
          | CheckExprCall Comparison A.Expr Type
          | CheckDotPattern A.Expr Term
          | CheckPatternShadowing A.SpineClause
          | CheckProjection Range QName Type
          | IsTypeCall A.Expr Sort
          | IsType_ A.Expr
          | InferVar Name
          | InferDef QName
          | CheckArguments Range [NamedArg A.Expr] Type (Maybe Type)
          | CheckTargetType Range Type Type
          | CheckDataDef Range Name [A.LamBinding] [A.Constructor]
          | CheckRecDef Range Name [A.LamBinding] [A.Constructor]
          | CheckConstructor QName Telescope Sort A.Constructor
          | CheckFunDefCall Range Name [A.Clause]
          | CheckPragma Range A.Pragma
          | CheckPrimitive Range Name A.Expr
          | CheckIsEmpty Range Type
          | CheckWithFunctionType A.Expr
          | CheckSectionApplication Range ModuleName A.ModuleApplication
          | CheckNamedWhere ModuleName
          | ScopeCheckExpr C.Expr
          | ScopeCheckDeclaration NiceDeclaration
          | ScopeCheckLHS C.QName C.Pattern
          | NoHighlighting
          | ModuleContents  -- ^ Interaction command: show module contents.
          | SetRange Range  -- ^ used by 'setCurrentRange'
    deriving Data

instance Pretty Call where
    pretty CheckClause{}             = text "CheckClause"
    pretty CheckPattern{}            = text "CheckPattern"
    pretty InferExpr{}               = text "InferExpr"
    pretty CheckExprCall{}           = text "CheckExprCall"
    pretty CheckLetBinding{}         = text "CheckLetBinding"
    pretty CheckProjection{}         = text "CheckProjection"
    pretty IsTypeCall{}              = text "IsTypeCall"
    pretty IsType_{}                 = text "IsType_"
    pretty InferVar{}                = text "InferVar"
    pretty InferDef{}                = text "InferDef"
    pretty CheckArguments{}          = text "CheckArguments"
    pretty CheckTargetType{}         = text "CheckTargetType"
    pretty CheckDataDef{}            = text "CheckDataDef"
    pretty CheckRecDef{}             = text "CheckRecDef"
    pretty CheckConstructor{}        = text "CheckConstructor"
    pretty CheckFunDefCall{}         = text "CheckFunDefCall"
    pretty CheckPragma{}             = text "CheckPragma"
    pretty CheckPrimitive{}          = text "CheckPrimitive"
    pretty CheckWithFunctionType{}   = text "CheckWithFunctionType"
    pretty CheckNamedWhere{}         = text "CheckNamedWhere"
    pretty ScopeCheckExpr{}          = text "ScopeCheckExpr"
    pretty ScopeCheckDeclaration{}   = text "ScopeCheckDeclaration"
    pretty ScopeCheckLHS{}           = text "ScopeCheckLHS"
    pretty CheckDotPattern{}         = text "CheckDotPattern"
    pretty CheckPatternShadowing{}   = text "CheckPatternShadowing"
    pretty SetRange{}                = text "SetRange"
    pretty CheckSectionApplication{} = text "CheckSectionApplication"
    pretty CheckIsEmpty{}            = text "CheckIsEmpty"
    pretty NoHighlighting{}          = text "NoHighlighting"
    pretty ModuleContents{}          = text "ModuleContents"

instance HasRange Call where
    getRange (CheckClause _ c)               = getRange c
    getRange (CheckPattern p _ _)            = getRange p
    getRange (InferExpr e)                   = getRange e
    getRange (CheckExprCall _ e _)           = getRange e
    getRange (CheckLetBinding b)             = getRange b
    getRange (CheckProjection r _ _)         = r
    getRange (IsTypeCall e s)                = getRange e
    getRange (IsType_ e)                     = getRange e
    getRange (InferVar x)                    = getRange x
    getRange (InferDef f)                    = getRange f
    getRange (CheckArguments r _ _ _)        = r
    getRange (CheckTargetType r _ _)         = r
    getRange (CheckDataDef i _ _ _)          = getRange i
    getRange (CheckRecDef i _ _ _)           = getRange i
    getRange (CheckConstructor _ _ _ c)      = getRange c
    getRange (CheckFunDefCall i _ _)         = getRange i
    getRange (CheckPragma r _)               = r
    getRange (CheckPrimitive i _ _)          = getRange i
    getRange CheckWithFunctionType{}         = noRange
    getRange (CheckNamedWhere m)             = getRange m
    getRange (ScopeCheckExpr e)              = getRange e
    getRange (ScopeCheckDeclaration d)       = getRange d
    getRange (ScopeCheckLHS _ p)             = getRange p
    getRange (CheckDotPattern e _)           = getRange e
    getRange (CheckPatternShadowing c)       = getRange c
    getRange (SetRange r)                    = r
    getRange (CheckSectionApplication r _ _) = r
    getRange (CheckIsEmpty r _)              = r
    getRange NoHighlighting                  = noRange
    getRange ModuleContents                  = noRange

---------------------------------------------------------------------------
-- ** Instance table
---------------------------------------------------------------------------

-- | The instance table is a @Map@ associating to every name of
--   record/data type/postulate its list of instances
type InstanceTable = Map QName (Set QName)

-- | When typechecking something of the following form:
--
--     instance
--       x : _
--       x = y
--
--   it's not yet known where to add @x@, so we add it to a list of
--   unresolved instances and we'll deal with it later.
type TempInstanceTable = (InstanceTable , Set QName)

---------------------------------------------------------------------------
-- ** Builtin things
---------------------------------------------------------------------------

data BuiltinDescriptor
  = BuiltinData (TCM Type) [String]
  | BuiltinDataCons (TCM Type)
  | BuiltinPrim String (Term -> TCM ())
  | BuiltinPostulate Relevance (TCM Type)
  | BuiltinUnknown (Maybe (TCM Type)) (Term -> Type -> TCM ())
    -- ^ Builtin of any kind.
    --   Type can be checked (@Just t@) or inferred (@Nothing@).
    --   The second argument is the hook for the verification function.

data BuiltinInfo =
   BuiltinInfo { builtinName :: String
               , builtinDesc :: BuiltinDescriptor }

type BuiltinThings pf = Map String (Builtin pf)

data Builtin pf
        = Builtin Term
        | Prim pf
    deriving (Show, Functor, Foldable, Traversable)

---------------------------------------------------------------------------
-- * Highlighting levels
---------------------------------------------------------------------------

-- | How much highlighting should be sent to the user interface?

data HighlightingLevel
  = None
  | NonInteractive
  | Interactive
    -- ^ This includes both non-interactive highlighting and
    -- interactive highlighting of the expression that is currently
    -- being type-checked.
    deriving (Eq, Ord, Show, Read, Data)

-- | How should highlighting be sent to the user interface?

data HighlightingMethod
  = Direct
    -- ^ Via stdout.
  | Indirect
    -- ^ Both via files and via stdout.
    deriving (Eq, Show, Read, Data)

-- | @ifTopLevelAndHighlightingLevelIs l b m@ runs @m@ when we're
-- type-checking the top-level module and either the highlighting
-- level is /at least/ @l@ or @b@ is 'True'.

ifTopLevelAndHighlightingLevelIsOr ::
  MonadTCM tcm => HighlightingLevel -> Bool -> tcm () -> tcm ()
ifTopLevelAndHighlightingLevelIsOr l b m = do
  e <- ask
  when (envModuleNestingLevel e == 0 &&
        (envHighlightingLevel e >= l || b))
       m

-- | @ifTopLevelAndHighlightingLevelIs l m@ runs @m@ when we're
-- type-checking the top-level module and the highlighting level is
-- /at least/ @l@.

ifTopLevelAndHighlightingLevelIs ::
  MonadTCM tcm => HighlightingLevel -> tcm () -> tcm ()
ifTopLevelAndHighlightingLevelIs l =
  ifTopLevelAndHighlightingLevelIsOr l False

---------------------------------------------------------------------------
-- * Type checking environment
---------------------------------------------------------------------------

data TCEnv =
    TCEnv { envContext             :: Context
          , envLetBindings         :: LetBindings
          , envCurrentModule       :: ModuleName
          , envCurrentPath         :: Maybe AbsolutePath
            -- ^ The path to the file that is currently being
            -- type-checked.  'Nothing' if we do not have a file
            -- (like in interactive mode see @CommandLine@).
          , envAnonymousModules    :: [(ModuleName, Nat)] -- ^ anonymous modules and their number of free variables
          , envImportPath          :: [C.TopLevelModuleName] -- ^ to detect import cycles
          , envMutualBlock         :: Maybe MutualId -- ^ the current (if any) mutual block
          , envTerminationCheck    :: TerminationCheck ()  -- ^ are we inside the scope of a termination pragma
          , envSolvingConstraints  :: Bool
                -- ^ Are we currently in the process of solving active constraints?
          , envCheckingWhere       :: Bool
                -- ^ Have we stepped into the where-declarations of a clause?
                --   Everything under a @where@ will be checked with this flag on.
          , envWorkingOnTypes      :: Bool
                -- ^ Are we working on types? Turned on by 'workOnTypes'.
          , envAssignMetas         :: Bool
            -- ^ Are we allowed to assign metas?
          , envActiveProblems      :: Set ProblemId
          , envAbstractMode        :: AbstractMode
                -- ^ When checking the typesignature of a public definition
                --   or the body of a non-abstract definition this is true.
                --   To prevent information about abstract things leaking
                --   outside the module.
          , envRelevance           :: Relevance
                -- ^ Are we checking an irrelevant argument? (=@Irrelevant@)
                -- Then top-level irrelevant declarations are enabled.
                -- Other value: @Relevant@, then only relevant decls. are avail.
          , envDisplayFormsEnabled :: Bool
                -- ^ Sometimes we want to disable display forms.
          , envRange :: Range
          , envHighlightingRange :: Range
                -- ^ Interactive highlighting uses this range rather
                --   than 'envRange'.
          , envClause :: IPClause
                -- ^ What is the current clause we are type-checking?
                --   Will be recorded in interaction points in this clause.
          , envCall  :: Maybe (Closure Call)
                -- ^ what we're doing at the moment
          , envHighlightingLevel  :: HighlightingLevel
                -- ^ Set to 'None' when imported modules are
                --   type-checked.
          , envHighlightingMethod :: HighlightingMethod
          , envModuleNestingLevel :: !Int
                -- ^ This number indicates how far away from the
                --   top-level module Agda has come when chasing
                --   modules. The level of a given module is not
                --   necessarily the same as the length, in the module
                --   dependency graph, of the shortest path from the
                --   top-level module; it depends on in which order
                --   Agda chooses to chase dependencies.
          , envAllowDestructiveUpdate :: Bool
                -- ^ When True, allows destructively shared updating terms
                --   during evaluation or unification. This is disabled when
                --   doing speculative checking, like solve instance metas, or
                --   when updating might break abstraction, as is the case when
                --   checking abstract definitions.
          , envExpandLast :: ExpandHidden
                -- ^ When type-checking an alias f=e, we do not want
                -- to insert hidden arguments in the end, because
                -- these will become unsolved metas.
          , envAppDef :: Maybe QName
                -- ^ We are reducing an application of this function.
                -- (For debugging of incomplete matches only.)
          , envSimplification :: Simplification
                -- ^ Did we encounter a simplification (proper match)
                --   during the current reduction process?
          , envAllowedReductions :: AllowedReductions
          , envInjectivityDepth :: Int
                -- ^ Injectivity can cause non-termination for unsolvable contraints
                --   (#431, #3067). Keep a limit on the nesting depth of injectivity
                --   uses.
          , envCompareBlocked :: Bool
                -- ^ Can we compare blocked things during conversion?
                --   No by default.
                --   Yes for rewriting feature.
          , envPrintDomainFreePi :: Bool
                -- ^ When @True@, types will be omitted from printed pi types if they
                --   can be inferred.
          , envPrintMetasBare :: Bool
                -- ^ When @True@, throw away meta numbers and meta elims.
                --   This is used for reifying terms for feeding into the
                --   user's source code, e.g., for the interaction tactics @solveAll@.
          , envInsideDotPattern :: Bool
                -- ^ Used by the scope checker to make sure that certain forms
                --   of expressions are not used inside dot patterns: extended
                --   lambdas and let-expressions.
          , envUnquoteFlags :: UnquoteFlags
          , envInstanceDepth :: !Int
                -- ^ Until we get a termination checker for instance search (#1743) we
                --   limit the search depth to ensure termination.
          , envIsDebugPrinting :: Bool
          , envPrintingPatternLambdas :: [QName]
                -- ^ #3004: pattern lambdas with copatterns may refer to themselves. We
                --   don't have a good story for what to do in this case, but at least
                --   printing shouldn't loop. Here we keep track of which pattern lambdas
                --   we are currently in the process of printing.
          , envCallByNeed :: Bool
                -- ^ Use call-by-need evaluation for reductions.
          , envCurrentCheckpoint :: CheckpointId
                -- ^ Checkpoints track the evolution of the context as we go
                -- under binders or refine it by pattern matching.
          , envCheckpoints :: Map CheckpointId Substitution
                -- ^ Keeps the substitution from each previous checkpoint to
                --   the current context.
          , envGeneralizeMetas :: DoGeneralize
                -- ^ Should new metas generalized over.
          , envGeneralizedVars :: Map QName GeneralizedValue
                -- ^ Values for used generalizable variables.
          }
    deriving Data

initEnv :: TCEnv
initEnv = TCEnv { envContext             = []
                , envLetBindings         = Map.empty
                , envCurrentModule       = noModuleName
                , envCurrentPath         = Nothing
                , envAnonymousModules    = []
                , envImportPath          = []
                , envMutualBlock         = Nothing
                , envTerminationCheck    = TerminationCheck
                , envSolvingConstraints  = False
                , envCheckingWhere       = False
                , envActiveProblems      = Set.empty
                , envWorkingOnTypes      = False
                , envAssignMetas         = True
                , envAbstractMode        = ConcreteMode
  -- Andreas, 2013-02-21:  This was 'AbstractMode' until now.
  -- However, top-level checks for mutual blocks, such as
  -- constructor-headedness, should not be able to look into
  -- abstract definitions unless abstract themselves.
  -- (See also discussion on issue 796.)
  -- The initial mode should be 'ConcreteMode', ensuring you
  -- can only look into abstract things in an abstract
  -- definition (which sets 'AbstractMode').
                , envRelevance           = Relevant
                , envDisplayFormsEnabled = True
                , envRange                  = noRange
                , envHighlightingRange      = noRange
                , envClause                 = IPNoClause
                , envCall                   = Nothing
                , envHighlightingLevel      = None
                , envHighlightingMethod     = Indirect
                , envModuleNestingLevel     = -1
                , envAllowDestructiveUpdate = True
                , envExpandLast             = ExpandLast
                , envAppDef                 = Nothing
                , envSimplification         = NoSimplification
                , envAllowedReductions      = allReductions
                , envInjectivityDepth       = 0
                , envCompareBlocked         = False
                , envPrintDomainFreePi      = False
                , envPrintMetasBare         = False
                , envInsideDotPattern       = False
                , envUnquoteFlags           = defaultUnquoteFlags
                , envInstanceDepth          = 0
                , envIsDebugPrinting        = False
                , envPrintingPatternLambdas = []
                , envCallByNeed             = True
                , envCurrentCheckpoint      = 0
                , envCheckpoints            = Map.singleton 0 IdS
                , envGeneralizeMetas        = NoGeneralize
                , envGeneralizedVars        = Map.empty
                }

disableDestructiveUpdate :: TCM a -> TCM a
disableDestructiveUpdate = local $ \e -> e { envAllowDestructiveUpdate = False }

data UnquoteFlags = UnquoteFlags
  { _unquoteNormalise :: Bool }
  deriving Data

defaultUnquoteFlags :: UnquoteFlags
defaultUnquoteFlags = UnquoteFlags
  { _unquoteNormalise = False }

unquoteNormalise :: Lens' Bool UnquoteFlags
unquoteNormalise f e = f (_unquoteNormalise e) <&> \ x -> e { _unquoteNormalise = x }

eUnquoteNormalise :: Lens' Bool TCEnv
eUnquoteNormalise = eUnquoteFlags . unquoteNormalise

-- * e-prefixed lenses
------------------------------------------------------------------------

eContext :: Lens' Context TCEnv
eContext f e = f (envContext e) <&> \ x -> e { envContext = x }

eLetBindings :: Lens' LetBindings TCEnv
eLetBindings f e = f (envLetBindings e) <&> \ x -> e { envLetBindings = x }

eCurrentModule :: Lens' ModuleName TCEnv
eCurrentModule f e = f (envCurrentModule e) <&> \ x -> e { envCurrentModule = x }

eCurrentPath :: Lens' (Maybe AbsolutePath) TCEnv
eCurrentPath f e = f (envCurrentPath e) <&> \ x -> e { envCurrentPath = x }

eAnonymousModules :: Lens' [(ModuleName, Nat)] TCEnv
eAnonymousModules f e = f (envAnonymousModules e) <&> \ x -> e { envAnonymousModules = x }

eImportPath :: Lens' [C.TopLevelModuleName] TCEnv
eImportPath f e = f (envImportPath e) <&> \ x -> e { envImportPath = x }

eMutualBlock :: Lens' (Maybe MutualId) TCEnv
eMutualBlock f e = f (envMutualBlock e) <&> \ x -> e { envMutualBlock = x }

eTerminationCheck :: Lens' (TerminationCheck ()) TCEnv
eTerminationCheck f e = f (envTerminationCheck e) <&> \ x -> e { envTerminationCheck = x }

eSolvingConstraints :: Lens' Bool TCEnv
eSolvingConstraints f e = f (envSolvingConstraints e) <&> \ x -> e { envSolvingConstraints = x }

eCheckingWhere :: Lens' Bool TCEnv
eCheckingWhere f e = f (envCheckingWhere e) <&> \ x -> e { envCheckingWhere = x }

eWorkingOnTypes :: Lens' Bool TCEnv
eWorkingOnTypes f e = f (envWorkingOnTypes e) <&> \ x -> e { envWorkingOnTypes = x }

eAssignMetas :: Lens' Bool TCEnv
eAssignMetas f e = f (envAssignMetas e) <&> \ x -> e { envAssignMetas = x }

eActiveProblems :: Lens' (Set ProblemId) TCEnv
eActiveProblems f e = f (envActiveProblems e) <&> \ x -> e { envActiveProblems = x }

eAbstractMode :: Lens' AbstractMode TCEnv
eAbstractMode f e = f (envAbstractMode e) <&> \ x -> e { envAbstractMode = x }

eRelevance :: Lens' Relevance TCEnv
eRelevance f e = f (envRelevance e) <&> \ x -> e { envRelevance = x }

eDisplayFormsEnabled :: Lens' Bool TCEnv
eDisplayFormsEnabled f e = f (envDisplayFormsEnabled e) <&> \ x -> e { envDisplayFormsEnabled = x }

eRange :: Lens' Range TCEnv
eRange f e = f (envRange e) <&> \ x -> e { envRange = x }

eHighlightingRange :: Lens' Range TCEnv
eHighlightingRange f e = f (envHighlightingRange e) <&> \ x -> e { envHighlightingRange = x }

eCall :: Lens' (Maybe (Closure Call)) TCEnv
eCall f e = f (envCall e) <&> \ x -> e { envCall = x }

eHighlightingLevel :: Lens' HighlightingLevel TCEnv
eHighlightingLevel f e = f (envHighlightingLevel e) <&> \ x -> e { envHighlightingLevel = x }

eHighlightingMethod :: Lens' HighlightingMethod TCEnv
eHighlightingMethod f e = f (envHighlightingMethod e) <&> \ x -> e { envHighlightingMethod = x }

eModuleNestingLevel :: Lens' Int TCEnv
eModuleNestingLevel f e = f (envModuleNestingLevel e) <&> \ x -> e { envModuleNestingLevel = x }

eAllowDestructiveUpdate :: Lens' Bool TCEnv
eAllowDestructiveUpdate f e = f (envAllowDestructiveUpdate e) <&> \ x -> e { envAllowDestructiveUpdate = x }

eExpandLast :: Lens' ExpandHidden TCEnv
eExpandLast f e = f (envExpandLast e) <&> \ x -> e { envExpandLast = x }

eAppDef :: Lens' (Maybe QName) TCEnv
eAppDef f e = f (envAppDef e) <&> \ x -> e { envAppDef = x }

eSimplification :: Lens' Simplification TCEnv
eSimplification f e = f (envSimplification e) <&> \ x -> e { envSimplification = x }

eAllowedReductions :: Lens' AllowedReductions TCEnv
eAllowedReductions f e = f (envAllowedReductions e) <&> \ x -> e { envAllowedReductions = x }

eInjectivityDepth :: Lens' Int TCEnv
eInjectivityDepth f e = f (envInjectivityDepth e) <&> \ x -> e { envInjectivityDepth = x }

eCompareBlocked :: Lens' Bool TCEnv
eCompareBlocked f e = f (envCompareBlocked e) <&> \ x -> e { envCompareBlocked = x }

ePrintDomainFreePi :: Lens' Bool TCEnv
ePrintDomainFreePi f e = f (envPrintDomainFreePi e) <&> \ x -> e { envPrintDomainFreePi = x }

eInsideDotPattern :: Lens' Bool TCEnv
eInsideDotPattern f e = f (envInsideDotPattern e) <&> \ x -> e { envInsideDotPattern = x }

eUnquoteFlags :: Lens' UnquoteFlags TCEnv
eUnquoteFlags f e = f (envUnquoteFlags e) <&> \ x -> e { envUnquoteFlags = x }

eInstanceDepth :: Lens' Int TCEnv
eInstanceDepth f e = f (envInstanceDepth e) <&> \ x -> e { envInstanceDepth = x }

eIsDebugPrinting :: Lens' Bool TCEnv
eIsDebugPrinting f e = f (envIsDebugPrinting e) <&> \ x -> e { envIsDebugPrinting = x }

ePrintingPatternLambdas :: Lens' [QName] TCEnv
ePrintingPatternLambdas f e = f (envPrintingPatternLambdas e) <&> \ x -> e { envPrintingPatternLambdas = x }

eCallByNeed :: Lens' Bool TCEnv
eCallByNeed f e = f (envCallByNeed e) <&> \ x -> e { envCallByNeed = x }

eCurrentCheckpoint :: Lens' CheckpointId TCEnv
eCurrentCheckpoint f e = f (envCurrentCheckpoint e) <&> \ x -> e { envCurrentCheckpoint = x }

eCheckpoints :: Lens' (Map CheckpointId Substitution) TCEnv
eCheckpoints f e = f (envCheckpoints e) <&> \ x -> e { envCheckpoints = x }

eGeneralizeMetas :: Lens' DoGeneralize TCEnv
eGeneralizeMetas f e = f (envGeneralizeMetas e) <&> \ x -> e { envGeneralizeMetas = x }

eGeneralizedVars :: Lens' (Map QName GeneralizedValue) TCEnv
eGeneralizedVars f e = f (envGeneralizedVars e) <&> \ x -> e { envGeneralizedVars = x }

---------------------------------------------------------------------------
-- ** Context
---------------------------------------------------------------------------

-- | The @Context@ is a stack of 'ContextEntry's.
type Context      = [ContextEntry]
type ContextEntry = Dom (Name, Type)

---------------------------------------------------------------------------
-- ** Let bindings
---------------------------------------------------------------------------

type LetBindings = Map Name (Open (Term, Dom Type))

---------------------------------------------------------------------------
-- ** Abstract mode
---------------------------------------------------------------------------

data AbstractMode
  = AbstractMode        -- ^ Abstract things in the current module can be accessed.
  | ConcreteMode        -- ^ No abstract things can be accessed.
  | IgnoreAbstractMode  -- ^ All abstract things can be accessed.
  deriving (Data, Show, Eq)

aDefToMode :: IsAbstract -> AbstractMode
aDefToMode AbstractDef = AbstractMode
aDefToMode ConcreteDef = ConcreteMode

aModeToDef :: AbstractMode -> IsAbstract
aModeToDef AbstractMode = AbstractDef
aModeToDef ConcreteMode = ConcreteDef
aModeToDef _ = __IMPOSSIBLE__

---------------------------------------------------------------------------
-- ** Insertion of implicit arguments
---------------------------------------------------------------------------

data ExpandHidden
  = ExpandLast      -- ^ Add implicit arguments in the end until type is no longer hidden 'Pi'.
  | DontExpandLast  -- ^ Do not append implicit arguments.
  deriving (Eq, Data)

data ExplicitToInstance
  = ExplicitToInstance    -- ^ Explicit arguments are considered as instance arguments
  | ExplicitStayExplicit
    deriving (Eq, Show, Data)

-- | A candidate solution for an instance meta is a term with its type.
--   It may be the case that the candidate is not fully applied yet or
--   of the wrong type, hence the need for the type.
data Candidate  = Candidate { candidateTerm :: Term
                            , candidateType :: Type
                            , candidateEti  :: ExplicitToInstance
                            , candidateOverlappable :: Bool
                            }
  deriving (Show, Data)

instance Free Candidate where
  freeVars' (Candidate t u _ _) = freeVars' (t, u)

---------------------------------------------------------------------------
-- * Type checking warnings (aka non-fatal errors)
---------------------------------------------------------------------------

-- | A non-fatal error is an error which does not prevent us from
-- checking the document further and interacting with the user.

data Warning
  = NicifierIssue            DeclarationWarning
  | TerminationIssue         [TerminationError]
  | UnreachableClauses       QName [[NamedArg DeBruijnPattern]]
  | CoverageIssue            QName [(Telescope, [NamedArg DeBruijnPattern])]
  -- ^ `CoverageIssue f pss` means that `pss` are not covered in `f`
  | CoverageNoExactSplit     QName [Clause]
  | NotStrictlyPositive      QName OccursWhere
  | UnsolvedMetaVariables    [Range]  -- ^ Do not use directly with 'warning'
  | UnsolvedInteractionMetas [Range]  -- ^ Do not use directly with 'warning'
  | UnsolvedConstraints      Constraints
    -- ^ Do not use directly with 'warning'
  | AbsurdPatternRequiresNoRHS [NamedArg DeBruijnPattern]
  | OldBuiltin               String String
    -- ^ In `OldBuiltin old new`, the BUILTIN old has been replaced by new
  | EmptyRewritePragma
    -- ^ If the user wrote just @{-# REWRITE #-}@.
  | UselessPublic
    -- ^ If the user opens a module public before the module header.
    --   (See issue #2377.)
  | UselessInline            QName
  | InversionDepthReached    QName
  -- ^ The --inversion-max-depth was reached.
  -- Generic warnings for one-off things
  | GenericWarning           Doc
    -- ^ Harmless generic warning (not an error)
  | GenericNonFatalError     Doc
    -- ^ Generic error which doesn't abort proceedings (not a warning)
  -- Safe flag errors
  | SafeFlagPostulate C.Name
  | SafeFlagPragma [String]
  | SafeFlagNonTerminating
  | SafeFlagTerminating
  | SafeFlagPrimTrustMe
  | SafeFlagNoPositivityCheck
  | SafeFlagPolarity
  | SafeFlagNoUniverseCheck
  | ParseWarning             ParseWarning
  | DeprecationWarning String String String
    -- ^ `DeprecationWarning old new version`:
    --   `old` is deprecated, use `new` instead. This will be an error in Agda `version`.
  | UserWarning String
    -- ^ User-defined warning (e.g. to mention that a name is deprecated)
  | ModuleDoesntExport C.QName [C.ImportedName]
    -- ^ Some imported names are not actually exported by the source module
  deriving (Show , Data)


warningName :: Warning -> WarningName
warningName w = case w of
  -- special cases
  NicifierIssue dw             -> declarationWarningName dw
  ParseWarning pw              -> parseWarningName pw
  -- typechecking errors
  AbsurdPatternRequiresNoRHS{} -> AbsurdPatternRequiresNoRHS_
  CoverageIssue{}              -> CoverageIssue_
  CoverageNoExactSplit{}       -> CoverageNoExactSplit_
  DeprecationWarning{}         -> DeprecationWarning_
  EmptyRewritePragma           -> EmptyRewritePragma_
  GenericNonFatalError{}       -> GenericNonFatalError_
  GenericWarning{}             -> GenericWarning_
  InversionDepthReached{}      -> InversionDepthReached_
  ModuleDoesntExport{}         -> ModuleDoesntExport_
  NotStrictlyPositive{}        -> NotStrictlyPositive_
  OldBuiltin{}                 -> OldBuiltin_
  SafeFlagNoPositivityCheck    -> SafeFlagNoPositivityCheck_
  SafeFlagNonTerminating       -> SafeFlagNonTerminating_
  SafeFlagNoUniverseCheck      -> SafeFlagNoUniverseCheck_
  SafeFlagPolarity             -> SafeFlagPolarity_
  SafeFlagPostulate{}          -> SafeFlagPostulate_
  SafeFlagPragma{}             -> SafeFlagPragma_
  SafeFlagPrimTrustMe          -> SafeFlagPrimTrustMe_
  SafeFlagTerminating          -> SafeFlagTerminating_
  TerminationIssue{}           -> TerminationIssue_
  UnreachableClauses{}         -> UnreachableClauses_
  UnsolvedInteractionMetas{}   -> UnsolvedInteractionMetas_
  UnsolvedConstraints{}        -> UnsolvedConstraints_
  UnsolvedMetaVariables{}      -> UnsolvedMetaVariables_
  UselessInline{}              -> UselessInline_
  UselessPublic                -> UselessPublic_
  UserWarning{}                -> UserWarning_




data TCWarning
  = TCWarning
    { tcWarningRange :: Range
        -- ^ Range where the warning was raised
    , tcWarning   :: Warning
        -- ^ The warning itself
    , tcWarningPrintedWarning :: Doc
        -- ^ The warning printed in the state and environment where it was raised
    , tcWarningCached :: Bool
        -- ^ Should the warning be affected by caching.
    }
  deriving Show


tcWarningOrigin :: TCWarning -> SrcFile
tcWarningOrigin = rangeFile . tcWarningRange

instance HasRange TCWarning where
  getRange = tcWarningRange

-- used for merging lists of warnings
instance Eq TCWarning where
  x == y = equalHeadConstructors (tcWarning x) (tcWarning y)
            && getRange x == getRange y

equalHeadConstructors :: Warning -> Warning -> Bool
equalHeadConstructors = (==) `on` toConstr

getPartialDefs :: ReadTCState tcm => tcm [QName]
getPartialDefs = do
  tcst <- getTCState
  return $ catMaybes . fmap (extractQName . tcWarning)
         $ tcst ^. stTCWarnings where

    extractQName :: Warning -> Maybe QName
    extractQName (CoverageIssue f _) = Just f
    extractQName _                   = Nothing

---------------------------------------------------------------------------
-- * Type checking errors
---------------------------------------------------------------------------

-- | Information about a call.

data CallInfo = CallInfo
  { callInfoTarget :: QName
    -- ^ Target function name.
  , callInfoRange :: Range
    -- ^ Range of the target function.
  , callInfoCall :: Closure Term
    -- ^ To be formatted representation of the call.
  } deriving (Data, Show)

-- no Eq, Ord instances: too expensive! (see issues 851, 852)

-- | We only 'show' the name of the callee.
instance Pretty CallInfo where pretty = pretty . callInfoTarget
instance AllNames CallInfo where allNames = singleton . callInfoTarget

-- UNUSED, but keep!
-- -- | Call pathes are sequences of 'CallInfo's starting from a 'callSource'.
-- data CallPath = CallPath
--   { callSource :: QName
--     -- ^ The originator of the first call.
--   , callInfos :: [CallInfo]
--     -- ^ The calls, in order from source to final target.
--   }
--   deriving (Show)

-- -- | 'CallPath'es can be connected, but there is no empty callpath.
-- --   Thus, they form a semigroup, but we choose to abuse 'Monoid'.
-- instance Monoid CallPath where
--   mempty = __IMPOSSIBLE__
--   mappend (CallPath src cs) (CallPath _ cs') = CallPath src $ cs ++ cs'

-- | Information about a mutual block which did not pass the
-- termination checker.

data TerminationError = TerminationError
  { termErrFunctions :: [QName]
    -- ^ The functions which failed to check. (May not include
    -- automatically generated functions.)
  , termErrCalls :: [CallInfo]
    -- ^ The problematic call sites.
  } deriving (Data, Show)

-- | Error when splitting a pattern variable into possible constructor patterns.
data SplitError
  = NotADatatype        (Closure Type)  -- ^ Neither data type nor record.
  | IrrelevantDatatype  (Closure Type)  -- ^ Data type, but in irrelevant position.
  | CoinductiveDatatype (Closure Type)  -- ^ Split on codata not allowed.
  -- UNUSED, but keep!
  -- -- | NoRecordConstructor Type  -- ^ record type, but no constructor
  | UnificationStuck
    { cantSplitConName  :: QName        -- ^ Constructor.
    , cantSplitTel      :: Telescope    -- ^ Context for indices.
    , cantSplitConIdx   :: Args         -- ^ Inferred indices (from type of constructor).
    , cantSplitGivenIdx :: Args         -- ^ Expected indices (from checking pattern).
    , cantSplitFailures :: [UnificationFailure] -- ^ Reason(s) why unification got stuck.
    }
  | GenericSplitError String
  deriving (Show)

data NegativeUnification
  = UnifyConflict Telescope Term Term
  | UnifyCycle Telescope Int Term
  deriving (Show)

data UnificationFailure
  = UnifyIndicesNotVars Telescope Type Term Term Args -- ^ Failed to apply injectivity to constructor of indexed datatype
  | UnifyRecursiveEq Telescope Type Int Term          -- ^ Can't solve equation because variable occurs in (type of) lhs
  | UnifyReflexiveEq Telescope Type Term              -- ^ Can't solve reflexive equation because --without-K is enabled
  deriving (Show)

data UnquoteError
  = BadVisibility String (Arg I.Term)
  | ConInsteadOfDef QName String String
  | DefInsteadOfCon QName String String
  | NonCanonical String I.Term
  | BlockedOnMeta TCState MetaId
  | UnquotePanic String
  deriving (Show)

data TypeError
        = InternalError String
        | NotImplemented String
        | NotSupported String
        | CompilationError String
        | PropMustBeSingleton
        | DataMustEndInSort Term
{- UNUSED
        | DataTooManyParameters
            -- ^ In @data D xs where@ the number of parameters @xs@ does not fit the
            --   the parameters given in the forward declaraion @data D Gamma : T@.
-}
        | ShouldEndInApplicationOfTheDatatype Type
            -- ^ The target of a constructor isn't an application of its
            -- datatype. The 'Type' records what it does target.
        | ShouldBeAppliedToTheDatatypeParameters Term Term
            -- ^ The target of a constructor isn't its datatype applied to
            --   something that isn't the parameters. First term is the correct
            --   target and the second term is the actual target.
        | ShouldBeApplicationOf Type QName
            -- ^ Expected a type to be an application of a particular datatype.
        | ConstructorPatternInWrongDatatype QName QName -- ^ constructor, datatype
        | CantResolveOverloadedConstructorsTargetingSameDatatype QName [QName]
          -- ^ Datatype, constructors.
        | DoesNotConstructAnElementOf QName Type -- ^ constructor, type
        | WrongHidingInLHS
            -- ^ The left hand side of a function definition has a hidden argument
            --   where a non-hidden was expected.
        | WrongHidingInLambda Type
            -- ^ Expected a non-hidden function and found a hidden lambda.
        | WrongHidingInApplication Type
            -- ^ A function is applied to a hidden argument where a non-hidden was expected.
        | WrongNamedArgument (NamedArg A.Expr)
            -- ^ A function is applied to a hidden named argument it does not have.
        | WrongIrrelevanceInLambda
            -- ^ Wrong user-given relevance annotation in lambda.
        | WrongInstanceDeclaration
            -- ^ A term is declared as an instance but it’s not allowed
        | HidingMismatch Hiding Hiding
            -- ^ The given hiding does not correspond to the expected hiding.
        | RelevanceMismatch Relevance Relevance
            -- ^ The given relevance does not correspond to the expected relevane.
        | UninstantiatedDotPattern A.Expr
        | ForcedConstructorNotInstantiated A.Pattern
        | IlltypedPattern A.Pattern Type
        | IllformedProjectionPattern A.Pattern
        | CannotEliminateWithPattern (NamedArg A.Pattern) Type
        | WrongNumberOfConstructorArguments QName Nat Nat
        | ShouldBeEmpty Type [DeBruijnPattern]
        | ShouldBeASort Type
            -- ^ The given type should have been a sort.
        | ShouldBePi Type
            -- ^ The given type should have been a pi.
        | ShouldBePath Type
        | ShouldBeRecordType Type
        | ShouldBeRecordPattern DeBruijnPattern
        | NotAProjectionPattern (NamedArg A.Pattern)
        | NotAProperTerm
        | InvalidTypeSort Sort
            -- ^ This sort is not a type expression.
        | InvalidType Term
            -- ^ This term is not a type expression.
        | FunctionTypeInSizeUniv Term
            -- ^ This term, a function type constructor, lives in
            --   @SizeUniv@, which is not allowed.
        | SplitOnIrrelevant (Dom Type)
        | SplitOnNonVariable Term Type
        | DefinitionIsIrrelevant QName
        | VariableIsIrrelevant Name
--        | UnequalLevel Comparison Term Term  -- UNUSED
        | UnequalTerms Comparison Term Term Type
        | UnequalTypes Comparison Type Type
--      | UnequalTelescopes Comparison Telescope Telescope -- UNUSED
        | UnequalRelevance Comparison Term Term
            -- ^ The two function types have different relevance.
        | UnequalHiding Term Term
            -- ^ The two function types have different hiding.
        | UnequalSorts Sort Sort
        | UnequalBecauseOfUniverseConflict Comparison Term Term
        | NotLeqSort Sort Sort
        | MetaCannotDependOn MetaId [Nat] Nat
            -- ^ The arguments are the meta variable, the parameters it can
            --   depend on and the paratemeter that it wants to depend on.
        | MetaOccursInItself MetaId
        | MetaIrrelevantSolution MetaId Term
        | GenericError String
        | GenericDocError Doc
        | BuiltinMustBeConstructor String A.Expr
        | NoSuchBuiltinName String
        | DuplicateBuiltinBinding String Term Term
        | NoBindingForBuiltin String
        | NoSuchPrimitiveFunction String
        | ShadowedModule C.Name [A.ModuleName]
        | BuiltinInParameterisedModule String
        | IllegalLetInTelescope C.TypedBinding
        | NoRHSRequiresAbsurdPattern [NamedArg A.Pattern]
        | TooFewFields QName [C.Name]
        | TooManyFields QName [C.Name]
        | DuplicateFields [C.Name]
        | DuplicateConstructors [C.Name]
        | WithOnFreeVariable A.Expr Term
        | UnexpectedWithPatterns [A.Pattern]
        | WithClausePatternMismatch A.Pattern (NamedArg DeBruijnPattern)
        | FieldOutsideRecord
        | ModuleArityMismatch A.ModuleName Telescope [NamedArg A.Expr]
        | GeneralizeCyclicDependency
        | GeneralizeUnsolvedMeta
    -- Coverage errors
-- UNUSED:        | IncompletePatternMatching Term [Elim] -- can only happen if coverage checking is switched off
        | SplitError SplitError
        | ImpossibleConstructor QName NegativeUnification
    -- Positivity errors
        | TooManyPolarities QName Int
    -- Import errors
        | LocalVsImportedModuleClash ModuleName
        | SolvedButOpenHoles
          -- ^ Some interaction points (holes) have not been filled by user.
          --   There are not 'UnsolvedMetas' since unification solved them.
          --   This is an error, since interaction points are never filled
          --   without user interaction.
        | CyclicModuleDependency [C.TopLevelModuleName]
        | FileNotFound C.TopLevelModuleName [AbsolutePath]
        | OverlappingProjects AbsolutePath C.TopLevelModuleName C.TopLevelModuleName
        | AmbiguousTopLevelModuleName C.TopLevelModuleName [AbsolutePath]
        | ModuleNameUnexpected C.TopLevelModuleName C.TopLevelModuleName
          -- ^ Found module name, expected module name.
        | ModuleNameDoesntMatchFileName C.TopLevelModuleName [AbsolutePath]
        | ClashingFileNamesFor ModuleName [AbsolutePath]
        | ModuleDefinedInOtherFile C.TopLevelModuleName AbsolutePath AbsolutePath
          -- ^ Module name, file from which it was loaded, file which
          -- the include path says contains the module.
    -- Scope errors
        | BothWithAndRHS
        | AbstractConstructorNotInScope A.QName
        | NotInScope [C.QName]
        | NoSuchModule C.QName
        | AmbiguousName C.QName (NonemptyList A.QName)
        | AmbiguousModule C.QName (NonemptyList A.ModuleName)
        | ClashingDefinition C.QName A.QName
        | ClashingModule A.ModuleName A.ModuleName
        | ClashingImport C.Name A.QName
        | ClashingModuleImport C.Name A.ModuleName
        | PatternShadowsConstructor A.Name A.QName
        | DuplicateImports C.QName [C.ImportedName]
        | InvalidPattern C.Pattern
        | RepeatedVariablesInPattern [C.Name]
        | GeneralizeNotSupportedHere A.QName
    -- Concrete to Abstract errors
        | NotAModuleExpr C.Expr
            -- ^ The expr was used in the right hand side of an implicit module
            --   definition, but it wasn't of the form @m Delta@.
        | NotAnExpression C.Expr
        | NotAValidLetBinding NiceDeclaration
        | NotValidBeforeField NiceDeclaration
        | NothingAppliedToHiddenArg C.Expr
        | NothingAppliedToInstanceArg C.Expr
    -- Pattern synonym errors
        | BadArgumentsToPatternSynonym A.AmbiguousQName
        | TooFewArgumentsToPatternSynonym A.AmbiguousQName
        | CannotResolveAmbiguousPatternSynonym (NonemptyList (A.QName, A.PatternSynDefn))
        | UnusedVariableInPatternSynonym
    -- Operator errors
        | NoParseForApplication [C.Expr]
        | AmbiguousParseForApplication [C.Expr] [C.Expr]
        | NoParseForLHS LHSOrPatSyn C.Pattern
        | AmbiguousParseForLHS LHSOrPatSyn C.Pattern [C.Pattern]
        | OperatorInformation [NotationSection] TypeError
{- UNUSED
        | NoParseForPatternSynonym C.Pattern
        | AmbiguousParseForPatternSynonym C.Pattern [C.Pattern]
-}
    -- Usage errors
    -- Implicit From Scope errors
        | IFSNoCandidateInScope Type
    -- Reflection errors
        | UnquoteFailed UnquoteError
        | DeBruijnIndexOutOfScope Nat Telescope [Name]
    -- Language option errors
        | NeedOptionCopatterns
        | NeedOptionRewriting
    -- Failure associated to warnings
        | NonFatalErrors [TCWarning]
    -- Instance search errors
        | InstanceSearchDepthExhausted Term Type Int
          deriving Show

-- | Distinguish error message when parsing lhs or pattern synonym, resp.
data LHSOrPatSyn = IsLHS | IsPatSyn deriving (Eq, Show)

-- | Type-checking errors.

data TCErr
  = TypeError
    { tcErrState   :: TCState
        -- ^ The state in which the error was raised.
    , tcErrClosErr :: Closure TypeError
        -- ^ The environment in which the error as raised plus the error.
    }
  | Exception Range Doc
  | IOException TCState Range E.IOException
    -- ^ The first argument is the state in which the error was
    -- raised.
  | PatternErr
      -- ^ The exception which is usually caught.
      --   Raised for pattern violations during unification ('assignV')
      --   but also in other situations where we want to backtrack.

instance Error TCErr where
  strMsg = Exception noRange . text . strMsg

instance Show TCErr where
  show (TypeError _ e)     = show (envRange $ clEnv e) ++ ": " ++ show (clValue e)
  show (Exception r d)     = show r ++ ": " ++ render d
  show (IOException _ r e) = show r ++ ": " ++ show e
  show PatternErr{}        = "Pattern violation (you shouldn't see this)"

instance HasRange TCErr where
  getRange (TypeError _ cl)    = envRange $ clEnv cl
  getRange (Exception r _)     = r
  getRange (IOException s r _) = r
  getRange PatternErr{}        = noRange

instance E.Exception TCErr

-----------------------------------------------------------------------------
-- * Accessing options
-----------------------------------------------------------------------------

class (Functor m, Applicative m, Monad m) => HasOptions m where
  -- | Returns the pragma options which are currently in effect.
  pragmaOptions      :: m PragmaOptions
  -- | Returns the command line options which are currently in effect.
  commandLineOptions :: m CommandLineOptions

instance MonadIO m => HasOptions (TCMT m) where
  pragmaOptions = use stPragmaOptions

  commandLineOptions = do
    p  <- use stPragmaOptions
    cl <- stPersistentOptions . stPersistentState <$> get
    return $ cl { optPragmaOptions = p }

instance HasOptions m => HasOptions (ExceptT e m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

instance HasOptions m => HasOptions (ListT m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

instance HasOptions m => HasOptions (MaybeT m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

instance HasOptions m => HasOptions (ReaderT r m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

instance HasOptions m => HasOptions (StateT s m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

instance (HasOptions m, Monoid w) => HasOptions (WriterT w m) where
  pragmaOptions      = lift pragmaOptions
  commandLineOptions = lift commandLineOptions

-----------------------------------------------------------------------------
-- * The reduce monad
-----------------------------------------------------------------------------

-- | Environment of the reduce monad.
data ReduceEnv = ReduceEnv
  { redEnv :: TCEnv    -- ^ Read only access to environment.
  , redSt  :: TCState  -- ^ Read only access to state (signature, metas...).
  }

mapRedEnv :: (TCEnv -> TCEnv) -> ReduceEnv -> ReduceEnv
mapRedEnv f s = s { redEnv = f (redEnv s) }

mapRedSt :: (TCState -> TCState) -> ReduceEnv -> ReduceEnv
mapRedSt f s = s { redSt = f (redSt s) }

mapRedEnvSt :: (TCEnv -> TCEnv) -> (TCState -> TCState) -> ReduceEnv
            -> ReduceEnv
mapRedEnvSt f g (ReduceEnv e s) = ReduceEnv (f e) (g s)

-- Lenses
reduceEnv :: Lens' TCEnv ReduceEnv
reduceEnv f s = f (redEnv s) <&> \ e -> s { redEnv = e }

reduceSt :: Lens' TCState ReduceEnv
reduceSt f s = f (redSt s) <&> \ e -> s { redSt = e }

newtype ReduceM a = ReduceM { unReduceM :: ReduceEnv -> a }
--  deriving (Functor, Applicative, Monad)

onReduceEnv :: (ReduceEnv -> ReduceEnv) -> ReduceM a -> ReduceM a
onReduceEnv f (ReduceM m) = ReduceM (m . f)

fmapReduce :: (a -> b) -> ReduceM a -> ReduceM b
fmapReduce f (ReduceM m) = ReduceM $ \ e -> f $! m e
{-# INLINE fmapReduce #-}

apReduce :: ReduceM (a -> b) -> ReduceM a -> ReduceM b
apReduce (ReduceM f) (ReduceM x) = ReduceM $ \ e -> f e $! x e
{-# INLINE apReduce #-}

bindReduce :: ReduceM a -> (a -> ReduceM b) -> ReduceM b
bindReduce (ReduceM m) f = ReduceM $ \ e -> unReduceM (f $! m e) e
{-# INLINE bindReduce #-}

instance Functor ReduceM where
  fmap = fmapReduce

instance Applicative ReduceM where
  pure x = ReduceM (const x)
  (<*>) = apReduce

instance Monad ReduceM where
  return = pure
  (>>=) = bindReduce
  (>>) = (*>)

instance ReadTCState ReduceM where
  getTCState = ReduceM redSt
  withTCState f = onReduceEnv $ mapRedSt f

runReduceM :: ReduceM a -> TCM a
runReduceM m = do
  e <- ask
  s <- get
  return $! unReduceM m (ReduceEnv e s)

runReduceF :: (a -> ReduceM b) -> TCM (a -> b)
runReduceF f = do
  e <- ask
  s <- get
  return $ \x -> unReduceM (f x) (ReduceEnv e s)

instance MonadReader TCEnv ReduceM where
  ask   = ReduceM redEnv
  local = onReduceEnv . mapRedEnv

useR :: (ReadTCState m) => Lens' a TCState -> m a
useR l = (^.l) <$> getTCState

askR :: ReduceM ReduceEnv
askR = ReduceM ask

localR :: (ReduceEnv -> ReduceEnv) -> ReduceM a -> ReduceM a
localR f = ReduceM . local f . unReduceM

instance HasOptions ReduceM where
  pragmaOptions      = useR stPragmaOptions
  commandLineOptions = do
    p  <- useR stPragmaOptions
    cl <- stPersistentOptions . stPersistentState <$> getTCState
    return $ cl{ optPragmaOptions = p }

class ( Applicative m
      , MonadReader TCEnv m
      , ReadTCState m
      , HasOptions m
      ) => MonadReduce m where
  liftReduce :: ReduceM a -> m a

instance MonadReduce m => MonadReduce (MaybeT m) where
  liftReduce = lift . liftReduce

instance MonadReduce m => MonadReduce (ListT m) where
  liftReduce = lift . liftReduce

instance MonadReduce m => MonadReduce (ExceptT err m) where
  liftReduce = lift . liftReduce

instance (Monoid w, MonadReduce m) => MonadReduce (WriterT w m) where
  liftReduce = lift . liftReduce

instance (MonadReduce m) => MonadReduce (StateT w m) where
  liftReduce = lift . liftReduce

instance MonadReduce ReduceM where
  liftReduce = id

---------------------------------------------------------------------------
-- * Type checking monad transformer
---------------------------------------------------------------------------

newtype TCMT m a = TCM { unTCM :: IORef TCState -> TCEnv -> m a }

-- TODO: make dedicated MonadTCEnv and MonadTCState service classes

instance MonadIO m => MonadReader TCEnv (TCMT m) where
  ask = TCM $ \s e -> return e
  local f (TCM m) = TCM $ \s e -> m s (f e)

instance MonadIO m => MonadState TCState (TCMT m) where
  get   = TCM $ \s _ -> liftIO (readIORef s)
  put s = TCM $ \r _ -> liftIO (writeIORef r s)

type TCM = TCMT IO

class ( Applicative tcm, MonadIO tcm
      , MonadReader TCEnv tcm
      , MonadState TCState tcm
      , HasOptions tcm
      ) => MonadTCM tcm where
    liftTCM :: TCM a -> tcm a

instance MonadIO m => ReadTCState (TCMT m) where
  getTCState = get
  withTCState f m = __IMPOSSIBLE__ -- should probably not be used

instance MonadError TCErr (TCMT IO) where
  throwError = liftIO . E.throwIO
  catchError m h = TCM $ \r e -> do
    oldState <- liftIO (readIORef r)
    unTCM m r e `E.catch` \err -> do
      -- Reset the state, but do not forget changes to the persistent
      -- component. Not for pattern violations.
      case err of
        PatternErr -> return ()
        _          ->
          liftIO $ do
            newState <- readIORef r
            writeIORef r $ oldState { stPersistentState = stPersistentState newState }
      unTCM (h err) r e

instance MonadIO m => MonadReduce (TCMT m) where
  liftReduce = liftTCM . runReduceM

-- | Interaction monad.

type IM = TCMT (Haskeline.InputT IO)

runIM :: IM a -> TCM a
runIM = mapTCMT (Haskeline.runInputT Haskeline.defaultSettings)

instance MonadError TCErr IM where
  throwError = liftIO . E.throwIO
  catchError m h = mapTCMT liftIO $ runIM m `catchError` (runIM . h)

-- | Preserve the state of the failing computation.
catchError_ :: TCM a -> (TCErr -> TCM a) -> TCM a
catchError_ m h = TCM $ \r e ->
  unTCM m r e
  `E.catch` \err -> unTCM (h err) r e

-- | Execute a finalizer even when an exception is thrown.
--   Does not catch any errors.
--   In case both the regular computation and the finalizer
--   throw an exception, the one of the finalizer is propagated.
finally_ :: TCM a -> TCM b -> TCM a
finally_ m f = do
    x <- m `catchError_` \ err -> f >> throwError err
    _ <- f
    return x

{-# SPECIALIZE INLINE mapTCMT :: (forall a. IO a -> IO a) -> TCM a -> TCM a #-}
mapTCMT :: (forall a. m a -> n a) -> TCMT m a -> TCMT n a
mapTCMT f (TCM m) = TCM $ \s e -> f (m s e)

pureTCM :: MonadIO m => (TCState -> TCEnv -> a) -> TCMT m a
pureTCM f = TCM $ \r e -> do
  s <- liftIO $ readIORef r
  return (f s e)

{-# RULES "liftTCM/id" liftTCM = id #-}
instance MonadIO m => MonadTCM (TCMT m) where
    liftTCM = mapTCMT liftIO

instance MonadTCM tcm => MonadTCM (MaybeT tcm) where
  liftTCM = lift . liftTCM

instance MonadTCM tcm => MonadTCM (ListT tcm) where
  liftTCM = lift . liftTCM

instance MonadTCM tcm => MonadTCM (ExceptT err tcm) where
  liftTCM = lift . liftTCM

instance (Monoid w, MonadTCM tcm) => MonadTCM (WriterT w tcm) where
  liftTCM = lift . liftTCM

{- The following is not possible since MonadTCM needs to be a
-- MonadState TCState and a MonadReader TCEnv

instance (MonadTCM tcm) => MonadTCM (StateT s tcm) where
  liftTCM = lift . liftTCM

instance (MonadTCM tcm) => MonadTCM (ReaderT r tcm) where
  liftTCM = lift . liftTCM
-}

instance MonadTrans TCMT where
    lift m = TCM $ \_ _ -> m

-- We want a special monad implementation of fail.
instance MonadIO m => Monad (TCMT m) where
    return = pure
    (>>=)  = bindTCMT
    (>>)   = (*>)
    fail   = internalError

-- One goal of the definitions and pragmas below is to inline the
-- monad operations as much as possible. This doesn't seem to have a
-- large effect on the performance of the normal executable, but (at
-- least on one machine/configuration) it has a massive effect on the
-- performance of the profiling executable [1], and reduces the time
-- attributed to bind from over 90% to about 25%.
--
-- [1] When compiled with -auto-all and run with -p: roughly 750%
-- faster for one example.

returnTCMT :: MonadIO m => a -> TCMT m a
returnTCMT = \x -> TCM $ \_ _ -> return x
{-# INLINE returnTCMT #-}

bindTCMT :: MonadIO m => TCMT m a -> (a -> TCMT m b) -> TCMT m b
bindTCMT = \(TCM m) k -> TCM $ \r e -> m r e >>= \x -> unTCM (k x) r e
{-# INLINE bindTCMT #-}

thenTCMT :: MonadIO m => TCMT m a -> TCMT m b -> TCMT m b
thenTCMT = \(TCM m1) (TCM m2) -> TCM $ \r e -> m1 r e >> m2 r e
{-# INLINE thenTCMT #-}

instance MonadIO m => Functor (TCMT m) where
  fmap = fmapTCMT

fmapTCMT :: MonadIO m => (a -> b) -> TCMT m a -> TCMT m b
fmapTCMT = \f (TCM m) -> TCM $ \r e -> liftM f (m r e)
{-# INLINE fmapTCMT #-}

instance MonadIO m => Applicative (TCMT m) where
  pure  = returnTCMT
  (<*>) = apTCMT

apTCMT :: MonadIO m => TCMT m (a -> b) -> TCMT m a -> TCMT m b
apTCMT = \(TCM mf) (TCM m) -> TCM $ \r e -> ap (mf r e) (m r e)
{-# INLINE apTCMT #-}

instance MonadIO m => MonadIO (TCMT m) where
  liftIO m = TCM $ \s e -> do
               let r = envRange e
               liftIO $ wrap s r $ do
                 x <- m
                 x `seq` return x
    where
      wrap s r m = E.catch m $ \e -> do
        s <- readIORef s
        E.throwIO $ IOException s r e

-- | We store benchmark statistics in an IORef.
--   This enables benchmarking pure computation, see
--   "Agda.Benchmarking".
instance MonadBench Phase TCM where
  getBenchmark = liftIO $ getBenchmark
  putBenchmark = liftIO . putBenchmark
  finally = finally_

instance Null (TCM Doc) where
  empty = return empty
  null = __IMPOSSIBLE__

-- | Short-cutting disjunction forms a monoid.
instance Semigroup (TCM Any) where
  ma <> mb = Any <$> do (getAny <$> ma) `or2M` (getAny <$> mb)

instance Monoid (TCM Any) where
  mempty = return mempty
  mappend = (<>)

patternViolation :: TCM a
patternViolation = throwError PatternErr

internalError :: MonadTCM tcm => String -> tcm a
internalError s = typeError $ InternalError s

genericError :: MonadTCM tcm => String -> tcm a
genericError = typeError . GenericError

{-# SPECIALIZE genericDocError :: Doc -> TCM a #-}
genericDocError :: MonadTCM tcm => Doc -> tcm a
genericDocError = typeError . GenericDocError

{-# SPECIALIZE typeError :: TypeError -> TCM a #-}
typeError :: MonadTCM tcm => TypeError -> tcm a
typeError err = liftTCM $ throwError =<< typeError_ err

{-# SPECIALIZE typeError_ :: TypeError -> TCM TCErr #-}
typeError_ :: MonadTCM tcm => TypeError -> tcm TCErr
typeError_ err = liftTCM $ TypeError <$> get <*> buildClosure err

-- | Running the type checking monad (most general form).
{-# SPECIALIZE runTCM :: TCEnv -> TCState -> TCM a -> IO (a, TCState) #-}
runTCM :: MonadIO m => TCEnv -> TCState -> TCMT m a -> m (a, TCState)
runTCM e s m = do
  r <- liftIO $ newIORef s
  a <- unTCM m r e
  s <- liftIO $ readIORef r
  return (a, s)

-- | Running the type checking monad on toplevel (with initial state).
runTCMTop :: TCM a -> IO (Either TCErr a)
runTCMTop m = (Right <$> runTCMTop' m) `E.catch` (return . Left)

runTCMTop' :: MonadIO m => TCMT m a -> m a
runTCMTop' m = do
  r <- liftIO $ newIORef initState
  unTCM m r initEnv

-- | 'runSafeTCM' runs a safe 'TCM' action (a 'TCM' action which cannot fail)
--   in the initial environment.

runSafeTCM :: TCM a -> TCState -> IO (a, TCState)
runSafeTCM m st = runTCM initEnv st m `E.catch` (\ (e :: TCErr) -> __IMPOSSIBLE__)
-- runSafeTCM m st = either__IMPOSSIBLE__ return <$> do
--     -- Errors must be impossible.
--     runTCM $ do
--         put st
--         a <- m
--         st <- get
--         return (a, st)

-- | Runs the given computation in a separate thread, with /a copy/ of
-- the current state and environment.
--
-- Note that Agda sometimes uses actual, mutable state. If the
-- computation given to @forkTCM@ tries to /modify/ this state, then
-- bad things can happen, because accesses are not mutually exclusive.
-- The @forkTCM@ function has been added mainly to allow the thread to
-- /read/ (a snapshot of) the current state in a convenient way.
--
-- Note also that exceptions which are raised in the thread are not
-- propagated to the parent, so the thread should not do anything
-- important.

forkTCM :: TCM a -> TCM ()
forkTCM m = do
  s <- get
  e <- ask
  liftIO $ void $ C.forkIO $ void $ runTCM e s m


-- | Base name for extended lambda patterns
extendedLambdaName :: String
extendedLambdaName = ".extendedlambda"

-- | Check whether we have an definition from an extended lambda.
isExtendedLambdaName :: A.QName -> Bool
isExtendedLambdaName = (extendedLambdaName `List.isPrefixOf`) . prettyShow . nameConcrete . qnameName

-- | Name of absurdLambda definitions.
absurdLambdaName :: String
absurdLambdaName = ".absurdlambda"

-- | Check whether we have an definition from an absurd lambda.
isAbsurdLambdaName :: QName -> Bool
isAbsurdLambdaName = (absurdLambdaName ==) . prettyShow . qnameName

---------------------------------------------------------------------------
-- * KillRange instances
---------------------------------------------------------------------------

instance KillRange Signature where
  killRange (Sig secs defs rews) = killRange2 Sig secs defs rews

instance KillRange Sections where
  killRange = fmap killRange

instance KillRange Definitions where
  killRange = fmap killRange

instance KillRange RewriteRuleMap where
  killRange = fmap killRange

instance KillRange Section where
  killRange (Section tel) = killRange1 Section tel

instance KillRange Definition where
  killRange (Defn ai name t pols occs gens displ mut compiled inst copy ma nc inj def) =
    killRange15 Defn ai name t pols occs gens displ mut compiled inst copy ma nc inj def
    -- TODO clarify: Keep the range in the defName field?

instance KillRange NLPat where
  killRange (PVar x y) = killRange2 PVar x y
  killRange (PWild)    = PWild
  killRange (PDef x y) = killRange2 PDef x y
  killRange (PLam x y) = killRange2 PLam x y
  killRange (PPi x y)  = killRange2 PPi x y
  killRange (PBoundVar x y) = killRange2 PBoundVar x y
  killRange (PTerm x)  = killRange1 PTerm x

instance KillRange NLPType where
  killRange (NLPType s a) = killRange2 NLPType s a

instance KillRange RewriteRule where
  killRange (RewriteRule q gamma f es rhs t) =
    killRange6 RewriteRule q gamma f es rhs t

instance KillRange CompiledRepresentation where
  killRange = id


instance KillRange EtaEquality where
  killRange = id

instance KillRange System where
  killRange (System tel sys) = System (killRange tel) (killRange sys)

instance KillRange ExtLamInfo where
  killRange (ExtLamInfo m sys) = killRange2 ExtLamInfo m sys

instance KillRange FunctionFlag where
  killRange = id

instance KillRange Defn where
  killRange def =
    case def of
      Axiom -> Axiom
      GeneralizableVar -> GeneralizableVar
      AbstractDefn{} -> __IMPOSSIBLE__ -- only returned by 'getConstInfo'!
      Function cls comp tt inv mut isAbs delayed proj flags term extlam with copat ->
        killRange13 Function cls comp tt inv mut isAbs delayed proj flags term extlam with copat
      Datatype a b c d e f g h       -> killRange8 Datatype a b c d e f g h
      Record a b c d e f g h i j k   -> killRange11 Record a b c d e f g h i j k
      Constructor a b c d e f g h i  -> killRange9 Constructor a b c d e f g h i
      Primitive a b c d e            -> killRange5 Primitive a b c d e

instance KillRange MutualId where
  killRange = id

instance KillRange c => KillRange (FunctionInverse' c) where
  killRange NotInjective = NotInjective
  killRange (Inverse m)  = Inverse $ killRangeMap m

instance KillRange TermHead where
  killRange SortHead     = SortHead
  killRange PiHead       = PiHead
  killRange (ConsHead q) = ConsHead $ killRange q
  killRange h@VarHead{}  = h
  killRange UnknownHead  = UnknownHead

instance KillRange Projection where
  killRange (Projection a b c d e) = killRange5 Projection a b c d e

instance KillRange ProjLams where
  killRange = id

instance KillRange a => KillRange (Open a) where
  killRange = fmap killRange

instance KillRange DisplayForm where
  killRange (Display n es dt) = killRange3 Display n es dt

instance KillRange Polarity where
  killRange = id

instance KillRange IsForced where
  killRange = id

instance KillRange DoGeneralize where
  killRange = id

instance KillRange DisplayTerm where
  killRange dt =
    case dt of
      DWithApp dt dts es -> killRange3 DWithApp dt dts es
      DCon q ci dts     -> killRange3 DCon q ci dts
      DDef q dts        -> killRange2 DDef q dts
      DDot v            -> killRange1 DDot v
      DTerm v           -> killRange1 DTerm v
