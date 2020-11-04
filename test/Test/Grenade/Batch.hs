{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeApplications    #-}

{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
module Test.Grenade.Shape where

import           Grenade.Core.Shape
import           Grenade.Core.Network
import           Grenade.Core.Layer
import           Grenade.Layers.FullyConnected
import           Grenade.Utils.ListStore

import           Numeric.LinearAlgebra hiding (uniformSample, konst, (===))
import           Numeric.LinearAlgebra.Static as H hiding ((===))
import           Numeric.LinearAlgebra.Devel as U 
import           Numeric.LinearAlgebra.Data as D hiding ((===))

import           Data.Maybe (fromJust)

import           Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import           GHC.TypeLits
import           Data.Proxy

import Debug.Trace

import           Test.Hedgehog.Compat

type FFNetwork = Network '[ FullyConnected 3 5 ] '[ 'D1 3, 'D1 5 ]

prop_feedforwardCalculatesOutputOfBatches = property $ do
  let bias :: H.R 5 = H.fromList [1..5]
      acts :: H.L 5 3 = H.fromList [1..15]
      fc :: FullyConnected 3 5 = FullyConnected (FullyConnected' bias acts) mkListStore
      ins :: [S ('D1 3)] = [S1D (H.fromList [1, 2, 3]), S1D (H.fromList [4, 5, 6])]
      (_, outs :: [S ('D1 5)]) = runBatchForwards fc ins
      outs' = map (\(S1D v) -> (D.toList . H.extract) v) outs
  outs' === [[15, 34, 53, 72, 91], [33, 79, 125, 171, 217]]

prop_backpropCalculatesGradients = property $ do
  let bias :: H.R 5 = H.fromList [1..5]
      acts :: H.L 5 3 = H.fromList [1..15]
      fc :: FullyConnected 3 5 = FullyConnected (FullyConnected' bias acts) mkListStore
      ins :: [S ('D1 3)] = [S1D (H.fromList [1, 2, 3]), S1D (H.fromList [4, 5, 6])]
      (tapes, outs :: [S ('D1 5)]) = runBatchForwards fc ins
      (grads, vs   :: [S ('D1 3)]) = runBatchBackwards fc tapes outs
      (grad,  v    :: S ('D1 3))   = runBackwards fc (tapes!!0) (outs!!0)
      (grad', v'   :: S ('D1 3))   = runBackwards fc (tapes!!1) (outs!!1)
      unwrapGrad                   = \(FullyConnected' wB wN) -> (H.extract wB, H.extract wN)
      grads'                       = map unwrapGrad grads
      grads''                      = map unwrapGrad [grad, grad']
      vs'                          = map (\(S1D v) -> (D.toList . H.extract) v) vs
      vs''                         = map (\(S1D v) -> (D.toList . H.extract) v) [v, v']

  grads' === grads''
  vs'    === vs''

prop_fullyConnectedAveragesGradients = property $ do
  let bias :: H.R 5 = H.fromList [1..5]
      acts :: H.L 5 3 = H.fromList [1..15]
      fc :: FullyConnected 3 5 = FullyConnected (FullyConnected' bias acts) mkListStore
      ins :: [S ('D1 3)] = [S1D (H.fromList [1, 2, 3]), S1D (H.fromList [4, 5, 6])]
      (tapes, outs :: [S ('D1 5)]) = runBatchForwards fc ins
      (grads, _    :: [S ('D1 3)]) = runBatchBackwards fc tapes outs
      (grad,  _    :: S ('D1 3))   = runBackwards fc (tapes!!0) (outs!!0)
      (grad', _    :: S ('D1 3))   = runBackwards fc (tapes!!1) (outs!!1)
      f                            = \(FullyConnected' wB wN) -> (H.extract wB, H.extract wN)
      rgrad                        = f (reduceGradient @(FullyConnected 3 5) grads)
      (wB, wN)                     = f grad
      (wB', wN')                   = f grad'
      rgrad'                       = (0.5 * (wB + wB'), 0.5 * (wN + wN'))

  rgrad === rgrad'
   
tests :: IO Bool
tests = checkParallel $$(discover)
