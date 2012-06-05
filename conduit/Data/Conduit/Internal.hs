{-# OPTIONS_HADDOCK not-home #-}
{-# OPTIONS_GHC -O2 #-} -- necessary to avoid some space leaks
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
module Data.Conduit.Internal
    ( -- * Types
      Pipe (..)
    , Source
    , Sink
    , Conduit
    , ResumablePipe (..)
      -- * Terminating pipes
    , await
    , awaitE
    , yield
    , yieldOr
    , bracketP
    , idP
      -- * Functions
    , pipe
    , pipePush
    , pipeResume
    , runPipe
    , sinkToPipe
    , hasInput
    , transPipe
    , mapOutput
    , mapOutputMaybe
    , mapInput
    , addCleanup
    , sourceList
    , leftover
    , injectLeftovers
    , anyLeftovers
    ) where

import Control.Applicative (Applicative (..), (<$>))
import Control.Monad ((>=>), liftM, ap)
import Control.Monad.Trans.Class (MonadTrans (lift))
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Base (MonadBase (liftBase))
import Data.Void (Void, absurd)
import Data.Monoid (Monoid (mappend, mempty))
import Control.Monad.Trans.Resource
import qualified GHC.Exts

-- | The underlying datatype for all the types in this package.  In has four
-- type parameters:
--
-- * /i/ is the type of values for this @Pipe@'s input stream.
--
-- * /o/ is the type of values for this @Pipe@'s output stream.
--
-- * /m/ is the underlying monad.
--
-- * /r/ is the result type.
--
-- Note that /o/ and /r/ are inherently different. /o/ is the type of the
-- stream of values this @Pipe@ will produce and send downstream. /r/ is the
-- final output of this @Pipe@.
--
-- Since 0.5.0
data Pipe l i o u m r =
    -- | Provide new output to be sent downstream. This constructor has three
    -- fields: the next @Pipe@ to be used, an early-closed function, and the
    -- output value.
    HaveOutput (Pipe l i o u m r) (m ()) o
    -- | Request more input from upstream. The first field takes a new input
    -- value and provides a new @Pipe@. The second is for early termination. It
    -- gives a new @Pipe@ which takes no input from upstream. This allows a
    -- @Pipe@ to provide a final stream of output values after no more input is
    -- available from upstream.
  | NeedInput (i -> Pipe l i o u m r) (u -> Pipe l i o u m r)
    -- | Processing with this @Pipe@ is complete, providing the final result.
  | Done r
    -- | Require running of a monadic action to get the next @Pipe@. Second
    -- field is an early cleanup function. Technically, this second field
    -- could be skipped, but doing so would require extra operations to be
    -- performed in some cases. For example, for a @Pipe@ pulling data from a
    -- file, it may be forced to pull an extra, unneeded chunk before closing
    -- the @Handle@.
  | PipeM (m (Pipe l i o u m r))
    -- | Return leftover input, which should be provided to future operations.
  | Leftover (Pipe l i o u m r) l

-- | A @Pipe@ which provides a stream of output values, without consuming any
-- input. The input parameter is set to @Void@ to indicate that this @Pipe@
-- takes no input.  A @Source@ is not used to produce a final result, and thus
-- the result parameter is set to @()@.
--
-- Since 0.4.0
type Source m a = Pipe Void Void a () m ()

-- | A @Pipe@ which consumes a stream of input values and produces a final
-- result. It cannot produce any output values, and thus the output parameter
-- is set to @Void@.
--
-- Since 0.4.0
type Sink i m r = Pipe i i Void () m r

-- | A @Pipe@ which consumes a stream of input values and produces a stream of
-- output values. It does not produce a result value, and thus the result
-- parameter is set to @()@.
--
-- Since 0.4.0
type Conduit i m o = Pipe i i o () m ()

pipePush :: Monad m => i -> Pipe i i o u m r -> Pipe i i o u m r
pipePush i (HaveOutput p c o) = HaveOutput (pipePush i p) c o
pipePush i (NeedInput p _) =
    case p i of
        Leftover p' i' -> pipePush i' p'
        p' -> p'
pipePush i (Done r) = Leftover (Done r) i
pipePush i (PipeM mp) = PipeM (pipePush i `liftM` mp)
pipePush i (Leftover p i') =
    case pipePush i' p of
        Leftover p'' i'' -> Leftover (Leftover p'' i'') i
        p' -> pipePush i p'

instance Monad m => Functor (Pipe l i o u m) where
    fmap = liftM

instance Monad m => Applicative (Pipe l i o u m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (Pipe l i o u m) where
    return = Done

    Done x           >>= fp = fp x
    HaveOutput p c o >>= fp = HaveOutput (p >>= fp)            c          o
    NeedInput p c    >>= fp = NeedInput  (p >=> fp)            (c >=> fp)
    PipeM mp         >>= fp = PipeM      ((>>= fp) `liftM` mp)
    Leftover p i     >>= fp = Leftover   (p >>= fp)            i

instance MonadBase base m => MonadBase base (Pipe l i o u m) where
    liftBase = lift . liftBase

instance MonadTrans (Pipe l i o u) where
    lift mr = PipeM (Done `liftM` mr)

instance MonadIO m => MonadIO (Pipe l i o u m) where
    liftIO = lift . liftIO

instance Monad m => Monoid (Pipe l i o u m ()) where
    mempty = return ()
    mappend = (>>)

idP :: Monad m => Pipe l a a r m r
idP = NeedInput (HaveOutput idP (return ())) Done

injectLeftovers :: Monad m => Pipe i i o u m r -> Pipe l i o u m r
injectLeftovers (Done r) = Done r
injectLeftovers (PipeM mp) = PipeM (liftM injectLeftovers mp)
injectLeftovers (NeedInput p c) = NeedInput (injectLeftovers . p) (injectLeftovers . c)
injectLeftovers (HaveOutput p c o) = HaveOutput (injectLeftovers p) c o
injectLeftovers (Leftover p0 i0) =
    injectLeftovers $ inject i0 p0
  where
    inject _ (Done r) = Done r
    inject i (NeedInput p _) = p i
    inject i (PipeM mp) = PipeM $ liftM (inject i) mp
    inject i (HaveOutput p c o) = HaveOutput (inject i p) c o
    inject i (Leftover p i') =
        case inject i' p of
            Leftover p' _ -> p'
            p' -> Leftover p' i

anyLeftovers :: Monad m => Pipe Void i o u m r -> Pipe l i o u m r
anyLeftovers (Leftover _ l) = absurd l
anyLeftovers (HaveOutput p c o) = HaveOutput (anyLeftovers p) c o
anyLeftovers (NeedInput p c) = NeedInput (anyLeftovers . p) (anyLeftovers . c)
anyLeftovers (Done r) = Done r
anyLeftovers (PipeM mp) = PipeM $ liftM anyLeftovers mp

-- | Compose a left and right pipe together into a complete pipe. The left pipe
-- will be automatically closed when the right pipe finishes, and any leftovers
-- from the right pipe will be discarded.
--
-- This is in fact a wrapper around 'pipeResume'. This function closes the left
-- @Pipe@ returns by @pipeResume@ and returns only the result.
--
-- Since 0.4.0
pipe :: Monad m => Pipe Void a b r0 m r1 -> Pipe Void b c r1 m r2 -> Pipe Void a c r0 m r2
pipe =
    pipe' (return ())
  where
    pipe' final left right =
        case right of
            Done r2 -> PipeM (final >> return (Done r2))
            HaveOutput p c o -> HaveOutput (pipe' final left p) c o
            PipeM mp -> PipeM (liftM (pipe' final left) mp)
            Leftover _ i -> absurd i
            NeedInput rp rc -> upstream rp rc
      where
        upstream rp rc =
            case left of
                Done r1 -> pipe (Done r1) (rc r1)
                HaveOutput left' final' o -> pipe' final' left' (rp o)
                PipeM mp -> PipeM (liftM (\left' -> pipe' final left' right) mp)
                Leftover _ i -> absurd i
                NeedInput left' lc -> NeedInput
                    (\a -> pipe' final (left' a) right)
                    (\r0 -> pipe' final (lc r0) right)

data ResumablePipe l i o u m r = ResumablePipe (Pipe l i o u m r) (m ())

-- | Same as 'pipe', but retain both the new left pipe and the leftovers from
-- the right pipe. The two components are combined together into a single pipe
-- and returned, together with the result of the right pipe.
--
-- Note: we're biased towards checking the right side first to avoid pulling
-- extra data which is not needed. Doing so could cause data loss.
--
-- Since 0.4.0
pipeResume :: Monad m
           => ResumablePipe a a b r0 m r1
           -> Pipe b b c r1 m r2
           -> Pipe a a c r0 m (ResumablePipe a a b r0 m r1, r2)
pipeResume leftTotal@(ResumablePipe left leftFinal) right =
    -- We're using a case statement instead of pattern matching in the function
    -- itself to make the logic explicit. We first check the right pipe, and
    -- only if the right pipe is asking for more input do we process the left
    -- pipe.
    case right of
        -- Right pipe is done, grab result and the left pipe
        Done r2 -> Done (leftTotal, r2)

        -- Right pipe needs to run a monadic action.
        PipeM mp -> PipeM (pipeResume leftTotal `liftM` mp)

        -- Right pipe has some output, provide it downstream and continue.
        HaveOutput p c o -> HaveOutput (pipeResume leftTotal p) c o

        Leftover p i -> pipeResume (ResumablePipe (HaveOutput left leftFinal i) leftFinal) p

        -- Right pipe needs input, so let's get it
        NeedInput rp rc ->
            case left of
                Leftover lp i ->
                    (\(ResumablePipe p pf, r) -> (ResumablePipe (Leftover p i) pf, r))
                    <$> pipeResume (ResumablePipe lp leftFinal) (NeedInput rp rc)
                -- Left pipe has output, right pipe wants it.
                HaveOutput lp lc a -> pipeResume (ResumablePipe lp lc) $ rp a

                -- Left pipe needs more input, ask for it.
                NeedInput p c -> NeedInput
                    (\a -> pipeResume (ResumablePipe (p a) leftFinal) right)
                    (\r0 -> pipeResume (ResumablePipe (c r0) leftFinal) right)

                -- Left pipe is done, right pipe needs input. In such a case,
                -- tell the right pipe there is no more input.
                Done r1 -> noInput r1 $ (ResumablePipe (Done r1) (return ()),) <$> rc r1

                -- Left pipe needs to run a monadic action.
                PipeM mp -> PipeM ((\p -> (ResumablePipe p leftFinal `pipeResume` right)) `liftM` mp)

noInput :: Monad m => u1 -> Pipe l1 i1 o u1 m r -> Pipe l i o u m r
noInput u (Leftover p _) = noInput u p
noInput _ (Done r2) = Done r2
noInput u (NeedInput _ rc') = noInput u (rc' u)
noInput u (HaveOutput p c o) = HaveOutput (noInput u p) c o
noInput u (PipeM mp) = PipeM (liftM (noInput u) mp)

-- | Run a complete pipeline until processing completes.
--
-- Since 0.4.0
runPipe :: Monad m => Pipe Void Void Void () m r -> m r
runPipe (HaveOutput _ _ o) = absurd o
runPipe (NeedInput _ c) = runPipe (c ())
runPipe (Done r) = return r
runPipe (PipeM mp) = mp >>= runPipe
runPipe (Leftover _ i) = absurd i

-- | Send a single output value downstream, and if it is accepted, continue
-- with the given @Pipe@.
--
-- Note that if you use monadic bind to include another @Pipe@ after this one,
-- it will be called regardless of whether downstream has completed. It is
-- therefore advisable in most cases to avoid such usage.
--
-- Since 0.5.0
yield :: Monad m
      => o -- ^ output value
      -> Pipe l i o u m ()
yield = HaveOutput (Done ()) (return ())

yieldOr :: Monad m
        => o
        -> m ()
        -> Pipe l i o u m ()
yieldOr o f = HaveOutput (Done ()) f o

{-# RULES
    "yield o >> p" forall o (p :: Pipe l i o u m r). yield o >> p = HaveOutput p  (return ()) o
  ; "mapM_ yield" mapM_ yield = sourceList
  #-}

-- | Provide a single piece of leftover input to be consumed by the next pipe
-- in the current monadic binding.
--
-- /Note/: it is highly encouraged to only return leftover values from input
-- already consumed from upstream.
--
-- Since 0.5.0
leftover :: l -> Pipe l i o u m ()
leftover = Leftover (Done ())
{-# INLINE [1] leftover #-}
{-# RULES "leftover l >> p" forall l (p :: Pipe l i o u m r). leftover l >> p = Leftover p l #-}

-- | Check if input is available from upstream. Will not remove the data from
-- the stream.
--
-- Since 0.4.0
hasInput :: Pipe i i o u m Bool -- FIXME consider removing
hasInput = NeedInput (Leftover (Done True)) (const $ Done False)

-- | A @Sink@ has a @Void@ type parameter for the output, which makes it
-- difficult to compose with @Source@s and @Conduit@s. This function replaces
-- that parameter with a free variable. This function is essentially @id@; it
-- only modifies the types, not the actions performed.
--
-- Since 0.4.0
sinkToPipe :: Monad m => Sink i m r -> Pipe i i o u m r
sinkToPipe (HaveOutput _ _ o) = absurd o
sinkToPipe (NeedInput p c) = NeedInput (sinkToPipe . p) (const $ sinkToPipe $ c ())
sinkToPipe (Done r) = Done r
sinkToPipe (PipeM mp) = PipeM (liftM sinkToPipe mp)
sinkToPipe (Leftover p i) = Leftover (sinkToPipe p) i

-- | Transform the monad that a @Pipe@ lives in.
--
-- Since 0.4.0
transPipe :: Monad m => (forall a. m a -> n a) -> Pipe l i o u m r -> Pipe l i o u n r
transPipe f (HaveOutput p c o) = HaveOutput (transPipe f p) (f c) o
transPipe f (NeedInput p c) = NeedInput (transPipe f . p) (transPipe f . c)
transPipe _ (Done r) = Done r
transPipe f (PipeM mp) = PipeM (f $ liftM (transPipe f) mp)
transPipe f (Leftover p i) = Leftover (transPipe f p) i

-- | Apply a function to all the output values of a `Pipe`.
--
-- This mimics the behavior of `fmap` for a `Source` and `Conduit` in pre-0.4
-- days.
--
-- Since 0.4.1
mapOutput :: Monad m => (o1 -> o2) -> Pipe l i o1 u m r -> Pipe l i o2 u m r
mapOutput f (HaveOutput p c o) = HaveOutput (mapOutput f p) c (f o)
mapOutput f (NeedInput p c) = NeedInput (mapOutput f . p) (mapOutput f . c)
mapOutput _ (Done r) = Done r
mapOutput f (PipeM mp) = PipeM (liftM (mapOutput f) mp)
mapOutput f (Leftover p i) = Leftover (mapOutput f p) i

mapOutputMaybe :: Monad m => (o1 -> Maybe o2) -> Pipe l i o1 u m r -> Pipe l i o2 u m r
mapOutputMaybe f (HaveOutput p c o) = maybe id (\o' p' -> HaveOutput p' c o') (f o) (mapOutputMaybe f p)
mapOutputMaybe f (NeedInput p c) = NeedInput (mapOutputMaybe f . p) (mapOutputMaybe f . c)
mapOutputMaybe _ (Done r) = Done r
mapOutputMaybe f (PipeM mp) = PipeM (liftM (mapOutputMaybe f) mp)
mapOutputMaybe f (Leftover p i) = Leftover (mapOutputMaybe f p) i

mapInput :: Monad m => (i1 -> i2) -> (l2 -> Maybe l1) -> Pipe l2 i2 o u m r -> Pipe l1 i1 o u m r
mapInput f f' (HaveOutput p c o) = HaveOutput (mapInput f f' p) c o
mapInput f f' (NeedInput p c)    = NeedInput (mapInput f f' . p . f) (mapInput f f' . c)
mapInput _ _  (Done r)           = Done r
mapInput f f' (PipeM mp)         = PipeM (liftM (mapInput f f') mp)
mapInput f f' (Leftover p i)     = maybe id (flip Leftover) (f' i) $ mapInput f f' p

-- | Add some code to be run when the given @Pipe@ cleans up.
--
-- Since 0.4.1
addCleanup :: Monad m
           => (Bool -> m ()) -- ^ @True@ if @Pipe@ ran to completion, @False@ for early termination.
           -> Pipe l i o u m r
           -> Pipe l i o u m r
addCleanup cleanup (Done r) = PipeM (cleanup True >> return (Done r))
addCleanup cleanup (HaveOutput src close x) = HaveOutput
    (addCleanup cleanup src)
    (cleanup False >> close)
    x
addCleanup cleanup (PipeM msrc) = PipeM (liftM (addCleanup cleanup) msrc)
addCleanup cleanup (NeedInput p c) = NeedInput
    (addCleanup cleanup . p)
    (addCleanup cleanup . c)
addCleanup cleanup (Leftover p i) = Leftover (addCleanup cleanup p) i

-- | Convert a list into a source.
--
-- Since 0.3.0
sourceList :: Monad m => [a] -> Pipe l i a u m ()
sourceList =
    go
  where
    go [] = Done ()
    go (o:os) = HaveOutput (go os) (return ()) o
{-# INLINE [1] sourceList #-}

-- | Wait for a single input value from upstream, terminating immediately if no
-- data is available.
--
-- Since 0.5.0
await :: Pipe l i o u m (Maybe i)
await = NeedInput (Done . Just) (\_ -> Done Nothing)
{-# RULES "await >>= maybe" forall x y. await >>= maybe x y = NeedInput y (const x) #-}
{-# INLINE [1] await #-}

awaitE :: Pipe l i o u m (Either u i)
awaitE = NeedInput (Done . Right) (Done . Left)
{-# RULES "awaitE >>= either" forall x y. awaitE >>= either x y = NeedInput y x #-}
{-# INLINE [1] awaitE #-}

-- | Perform some allocation and run an inner @Pipe@. Two guarantees are given
-- about resource finalization:
--
-- 1. It will be /prompt/. The finalization will be run as early as possible.
--
-- 2. It is exception safe. Due to usage of @resourcet@, the finalization will
--    be run in the event of any exceptions.
--
-- Since 0.5.0
bracketP :: MonadResource m
         => IO a
         -> (a -> IO ())
         -> (a -> Pipe l i o u m r)
         -> Pipe l i o u m r
bracketP alloc free inside =
    PipeM start
  where
    start = do
        (key, seed) <- allocate alloc free
        return $ addCleanup (const $ release key) (inside seed)

-- | The equivalent of @GHC.Exts.build@ for @Pipe@.
--
-- Since 0.4.2
build :: Monad m => (forall b. (o -> b -> b) -> b -> b) -> Pipe l i o u m ()
build g = g (\o p -> HaveOutput p (return ()) o) (return ())

{-# RULES
    "sourceList/build" forall (f :: (forall b. (a -> b -> b) -> b -> b)). sourceList (GHC.Exts.build f) = build f
  #-}
