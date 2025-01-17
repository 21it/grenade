{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-|
Module      : Grenade.Core.Network
Description : Core definition of a Neural Network
Copyright   : (c) Huw Campbell, 2016-2017
License     : BSD2
Stability   : experimental

This module defines the core data types and functions
for non-recurrent neural networks.
-}

module Grenade.Core.Network (
    Network (..)
  , CreatableNetwork (..)
  , RunnableNetwork (..)
  , Gradients (..)
  , Tapes (..)
  , FoldableGradient (..)

  , l2Norm
  , clipByGlobalNorm
  , batchRunNetwork
  , runGradient
  , batchRunGradient
  , applyUpdate
  , randomNetwork
  , randomNetworkInitWith
  ) where

import           Control.DeepSeq
import           Control.Monad.IO.Class
import           Control.Monad.Primitive           (PrimBase, PrimState)
import           Control.Parallel.Strategies
import           Data.Serialize
import           Data.Singletons
import           Prelude.Singletons
import           System.Random.MWC
#if MIN_VERSION_base(4,9,0)
import           Data.Kind                         (Type)
#endif

import           Grenade.Core.Layer
import           Grenade.Core.NetworkSettings
import           Grenade.Core.Optimizer
import           Grenade.Core.Shape
import           Grenade.Core.WeightInitialization
import           Grenade.Types

-- | Type of a network.
--
--   The @[*]@ type specifies the types of the layers.
--
--   The @[Shape]@ type specifies the shapes of data passed between the layers.
--
--   Can be considered to be a heterogeneous list of layers which are able to
--   transform the data shapes of the network.
data Network :: [Type] -> [Shape] -> Type where
    NNil  :: SingI i
          => Network '[] '[i]

    (:~>) :: (SingI i, SingI h, Layer x i h)
          => !x
          -> !(Network xs (h ': hs))
          -> Network (x ': xs) (i ': h ': hs)
infixr 5 :~>

instance Show (Network '[] '[i]) where
  show NNil = "NNil"
instance (Show x, Show (Network xs rs)) => Show (Network (x ': xs) (i ': rs)) where
  show (x :~> xs) = show x ++ " ~> " ++ show xs

instance NFData (Network '[] '[ i]) where
  rnf NNil = ()
instance (NFData x, NFData (Network xs rs)) => NFData (Network (x ': xs) (i ': rs)) where
  rnf ((!x) :~> (!xs)) = rnf x `seq` rnf xs

-- | Gradient of a network.
--
--   Parameterised on the layers of the network.
data Gradients :: [Type] -> Type where
   GNil  :: Gradients '[]

   (:/>) :: UpdateLayer x
         => !(Gradient x)
         -> !(Gradients xs)
         -> Gradients (x ': xs)

instance NFData (Gradients '[]) where
  rnf GNil = ()
instance (NFData (Gradient x), NFData (Gradients xs)) => NFData (Gradients (x ': xs)) where
  rnf (g :/> gs) = rnf g `seq` rnf gs

-- | BatchGradients of a network.
--
-- BatchGradients consist of a list of lists of gradients of layers,
-- parameterised on the layers of a network.
data BatchGradients :: [Type] -> Type where
  DNil   :: BatchGradients '[]

  (:/>>) :: UpdateLayer x
         => !([Gradient x])
         -> !(BatchGradients xs)
         -> BatchGradients (x ': xs)

-- Reduces BatchGradients into Gradients, by calling reduceGradient on each list
-- of gradients.
reduceBatchGradients :: forall layers. BatchGradients layers -> Gradients layers
reduceBatchGradients DNil = GNil
reduceBatchGradients (gs :/>> rest) = grad :/> (reduceBatchGradients rest)
  where
    grad = reduceGradient @(Head layers) gs

instance NFData (BatchGradients '[]) where
  rnf DNil = ()
instance (NFData (Gradient x), NFData (BatchGradients xs)) => NFData (BatchGradients (x ': xs)) where
  rnf (g :/>> gs) = rnf g `seq` rnf gs


instance Serialize (Gradients '[]) where
  put GNil = put ()
  get = return GNil
instance (UpdateLayer x, Serialize (Gradient x), Serialize (Gradients xs)) => Serialize (Gradients (x ': xs)) where
  put (g :/> gs) = put g >> put gs
  get = (:/>) <$> get <*> get


-- | Wegnert Tape of a network.
--
--   Parameterised on the layers and shapes of the network.
data Tapes :: [Type] -> [Shape] -> Type where
   TNil  :: SingI i
         => Tapes '[] '[i]

   (:\>) :: (SingI i, SingI h, Layer x i h)
         => !(Tape x i h)
         -> !(Tapes xs (h ': hs))
         -> Tapes (x ': xs) (i ': h ': hs)

instance NFData (Tapes '[] '[i]) where
  rnf TNil       = ()

instance (NFData (Tape x i h), NFData (Tapes xs (h ': hs))) => NFData (Tapes (x ': xs) (i ': h ': hs)) where
  rnf (t :\> ts) = rnf t `seq` rnf ts

-- | Wegnert Tape of a network.
--
--   Parameterised on the layers and shapes of the network.
data BatchTapes :: [Type] -> [Shape] -> Type where
   BTNil  :: SingI i
         => BatchTapes '[] '[i]

   (:\\>) :: (SingI i, SingI h, Layer x i h)
         => !([Tape x i h])
         -> !(BatchTapes xs (h ': hs))
         -> BatchTapes (x ': xs) (i ': h ': hs)

instance NFData (BatchTapes '[] '[i]) where
  rnf BTNil       = ()

instance (NFData ([Tape x i h]), NFData (BatchTapes xs (h ': hs))) => NFData (BatchTapes (x ': xs) (i ': h ': hs)) where
  rnf (t :\\> ts) = rnf t `seq` rnf ts

class RunnableNetwork layers shapes where
  -- | Running a network forwards with some input data.
  --
  --   This gives the output, and the Wengert tape required for back
  --   propagation.
  runNetwork :: Network layers shapes
             -> S (Head shapes)
             -> (Tapes layers shapes, S (Last shapes))

instance RunnableNetwork '[] '[i] where
  runNetwork NNil          !x = (TNil, x)

instance (RunnableNetwork xs (h ': hs), Layer x i h)
      => RunnableNetwork (x ': xs) (i ': h ': hs) where
  runNetwork (layer :~> n) !x =
    let (tape, !forward) = runForwards layer x
        (tapes, !answer) = runNetwork n forward
    in  (tape :\> tapes, answer)

-- | Running a network forwards with a batch input data.
--
--   This gives the batch of outputs, and the batch of Wengert
--   tapes required for back propagation.
batchRunNetwork :: forall layers shapes.
                   Network layers shapes
                   -> [S (Head shapes)]
                   -> (BatchTapes layers shapes, [S (Last shapes)])
batchRunNetwork = go
  where
    go  :: forall js ss. (Last js ~ Last shapes)
        => Network ss js
        -> [S (Head js)]
        -> (BatchTapes ss js, [S (Last js)])
    go (layer :~> n) !x =
      let (batchTape, forwards) = runBatchForwards layer x
          (batchTapes, answers) = go n forwards
      in  (batchTape :\\> batchTapes, answers)

    go NNil !xs
        = (BTNil, xs)

-- | Running a loss gradient back through the network.
--
--   This requires a Wengert tape, generated with the appropriate input
--   for the loss.
--
--   Gives the gradients for the layer, and the gradient across the
--   input (which may not be required).
runGradient :: forall layers shapes.
               Network layers shapes
            -> Tapes layers shapes
            -> S (Last shapes)
            -> (Gradients layers, S (Head shapes))
runGradient net tapes o =
  go net tapes
    where
  go  :: forall js ss. (Last js ~ Last shapes)
      => Network ss js
      -> Tapes ss js
      -> (Gradients ss, S (Head js))
  go (layer :~> n) (tape :\> nt) =
    let (gradients, feed)  = go n nt
        (layer', backGrad) = runBackwards layer tape feed
    in  (layer' :/> gradients, backGrad)

  go NNil TNil
      = (GNil, o)

-- | Running a batch of loss gradients back through the network.
--
--   This requires a batch of Wengert tape, generated with the appropriate input
--   for the loss.
--
--   It reduces the batch of gradients across the layers to produces the gradient across
--   the layers, and the gradient across the input (which may not be required).
batchRunGradient :: forall layers shapes.
               Network layers shapes
            -> BatchTapes layers shapes
            -> [S (Last shapes)]
            -> (Gradients layers, [S (Head shapes)])
batchRunGradient net tapes os =
  go net tapes
    where
      go  :: forall js ss.
             ( Last js ~ Last shapes)
          => Network ss js
          -> BatchTapes ss js
          -> (Gradients ss, [S (Head js)])
      go (layer :~> n) (tapes :\\> nt) =
        let (gradients, feeds)    = go n nt
            (grads , backGrads)   = runBatchBackwards layer tapes feeds
            grad                  = reduceGradient @(Head ss) grads
        in  (grad :/> gradients, backGrads)

      go NNil BTNil
          = (GNil, os)

-- | Apply one step of stochastic gradient descent across the network.
applyUpdate :: Optimizer opt
            -> Network layers shapes
            -> Gradients layers
            -> Network layers shapes
applyUpdate rate (layer :~> rest) (gradient :/> grest) =
  let layer' = runUpdate rate layer gradient
      rest' = applyUpdate rate rest grest `using` rpar
   in layer' :~> rest'
applyUpdate _ NNil GNil = NNil

-- | Apply network settings across the network.
applySettingsUpdate :: NetworkSettings -> Network layers shapes -> Network layers shapes
applySettingsUpdate settings (layer :~> rest) =
  let layer' = runSettingsUpdate settings layer
      layers' = applySettingsUpdate settings rest `using` rpar
   in layer' :~> layers'
applySettingsUpdate _ NNil = NNil


-- | A network can easily be created by hand with (:~>), but an easy way to
--   initialise a random network is with the @randomNetworkWith@ function.
class CreatableNetwork (xs :: [Type]) (ss :: [Shape]) where
  -- | Create a network with randomly initialised weights.
  --
  --   Calls to this function will not compile if the type of the neural
  --   network is not sound.
  randomNetworkWith :: PrimBase m => WeightInitMethod -> Gen (PrimState m) -> m (Network xs ss)

-- | Create a random network using uniform distribution.
randomNetwork :: (MonadIO m, CreatableNetwork xs ss) => m (Network xs ss)
randomNetwork = randomNetworkInitWith UniformInit

-- | Create a random network using the specified weight initialization method.
randomNetworkInitWith :: (MonadIO m, CreatableNetwork xs ss) => WeightInitMethod -> m (Network xs ss)
randomNetworkInitWith m = liftIO $ withSystemRandom . asGenST $ \gen -> randomNetworkWith m gen

instance SingI i => CreatableNetwork '[] '[i] where
  randomNetworkWith _  _ = return NNil

instance (SingI i, SingI o, Layer x i o, RandomLayer x, CreatableNetwork xs (o ': rs)) => CreatableNetwork (x ': xs) (i ': o ': rs) where
  randomNetworkWith m gen = (:~>) <$> createRandomWith m gen <*> randomNetworkWith m gen

-- | Add very simple serialisation to the network
instance SingI i => Serialize (Network '[] '[i]) where
  put NNil = pure ()
  get      = pure NNil

instance (SingI i, SingI o, Layer x i o, Serialize x, Serialize (Network xs (o ': rs))) => Serialize (Network (x ': xs) (i ': o ': rs)) where
  put (x :~> r) = put x >> put r
  get = (:~>) <$> get <*> get

-- | Ultimate composition.
--
--   This allows a complete network to be treated as a layer in a larger network.
instance UpdateLayer (Network sublayers subshapes) where
  type Gradient (Network sublayers subshapes) = Gradients sublayers
  runUpdate = applyUpdate
  runSettingsUpdate = applySettingsUpdate
  reduceGradient = (reduceBatchGradients . buildBatchGradients)
    where
      buildBatchGradients :: [Gradients sublayers] -> BatchGradients sublayers
      -- We don't have an [] base case because we need an instance of Gradients
      -- in order to analyse the number of layers and create the corresponding lists.
      buildBatchGradients []       = error "Attempting to infer structure from empty network in buildBatchGradients"
      buildBatchGradients [gs]     = buildSingletonBatches gs
      buildBatchGradients (gs:gss) = buildBatchGradients' gs (buildBatchGradients gss)

      -- We use this to initialize the BatchGradients
      buildSingletonBatches :: forall x. Gradients x -> BatchGradients x
      buildSingletonBatches GNil = DNil
      buildSingletonBatches (gx :/> gxx)  = [gx] :/>> (buildSingletonBatches gxx)

      -- Accumulates the BatchGradients and prepends the new gradients
      -- We expect the Gradients and the BatchGradients to have the same length, equal
      -- to the number of layers in the network.
      buildBatchGradients' :: forall x. Gradients x -> BatchGradients x -> BatchGradients x
      buildBatchGradients' GNil DNil = DNil
      buildBatchGradients' (gx :/> gxx)  (dx :/>> dxx)  = (gx:dx) :/>> (buildBatchGradients' gxx dxx)

instance FoldableGradient (Gradients '[]) where
  mapGradient _ GNil = GNil
  squaredSums GNil = []

instance (FoldableGradient (Gradient x), FoldableGradient (Gradients xs)) => FoldableGradient (Gradients (x ': xs)) where
  mapGradient f (x :/> xs) =
    let x' = mapGradient f x
        xs' = mapGradient f xs
     in x' :/> xs'
  squaredSums (x :/> xs) = squaredSums x ++ squaredSums xs

-- | Get the L2 Norm of a Foldable Gradient.
l2Norm :: (FoldableGradient x) => x -> RealNum
l2Norm grad = sqrt (sum $ squaredSums grad)

-- | Clip the gradients by the global norm.
clipByGlobalNorm :: (FoldableGradient (Gradients xs)) => RealNum -> Gradients xs -> Gradients xs
clipByGlobalNorm c grads =
  let divisor = sqrt $ sum $ squaredSums grads
   in if divisor > c
        then mapGradient (* (c / divisor)) grads
        else grads


instance CreatableNetwork sublayers subshapes => RandomLayer (Network sublayers subshapes) where
  createRandomWith = randomNetworkWith


-- | Ultimate composition.
--
--   This allows a complete network to be treated as a layer in a larger network.
instance (i ~ (Head subshapes), o ~ (Last subshapes), RunnableNetwork sublayers subshapes)
      => Layer (Network sublayers subshapes) i o where
  type Tape (Network sublayers subshapes) i o = Tapes sublayers subshapes
  runForwards  = runNetwork
  runBackwards = runGradient
