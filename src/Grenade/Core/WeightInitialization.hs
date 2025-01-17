{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}

{-|
Module      : Grenade.Core.WeightInitialization
Description : Defines the Weight Initialization methods of Grenade.
Copyright   : (c) Manuel Schneckenreither, 2018
License     : BSD2
Stability   : experimental

This module defines the weight initialization methods.

-}


module Grenade.Core.WeightInitialization
    ( getRandomVector
    , getRandomMatrix
    , WeightInitMethod (..)
    ) where

import           Control.Monad
import           Control.Monad.Primitive         (PrimBase, PrimState)
import           Data.Proxy
import           GHC.TypeLits.Singletons
import           GHC.TypeLits                    hiding (natVal)
import           Numeric.LinearAlgebra.Static
import           System.Random.MWC
import           System.Random.MWC.Distributions

-- ^ Weight initialization method.
data WeightInitMethod
  = UniformInit -- ^ W_l,i ~ U(-1/sqrt(n_l),1/sqrt(n_l))                   where n_l is the number of nodes in layer l
  | Xavier      -- ^ W_l,i ~ U(-sqrt (6/n_l+n_{l+1}),sqrt (6/n_l+n_{l+1})) where n_l is the number of nodes in layer l
  | HeEtAl      -- ^ W_l,i ~ N(0,sqrt(2/n_l))                              where n_l is the number of nodes in layer l


-- | Get a random vector initialized according to the specified method.
getRandomVector ::
     forall m n. (PrimBase m, KnownNat n)
  => Integer
  -> Integer
  -> WeightInitMethod
  -> Gen (PrimState m)
  -> m (R n)
getRandomVector i o method gen = do
  unifRands <- vector <$> replicateM n (uniformR (-1, 1) gen)
  gaussRands <- vector <$> replicateM n (realToFrac <$> standard gen)
  return $
    case method of
      UniformInit -> (1 / sqrt (fromIntegral i)) * unifRands
      Xavier      -> (sqrt 6 / sqrt (fromIntegral i + fromIntegral o)) * unifRands
      HeEtAl      -> sqrt (2 / fromIntegral i) * gaussRands
  where
    n = fromIntegral $ natVal (Proxy :: Proxy n)


-- | Get a matrix with weights initialized according to the specified method.
getRandomMatrix ::
     forall m r n. (PrimBase m, KnownNat r, KnownNat n, KnownNat (n * r))
  => Integer
  -> Integer
  -> WeightInitMethod
  -> Gen (PrimState m)
  -> m (L r n)
getRandomMatrix i o method gen = do
  unifRands <- matrix <$> replicateM nr (uniformR (-1, 1) gen)
  gaussRands <- matrix <$> replicateM nr (realToFrac <$> standard gen)
  return $
    case method of
      UniformInit -> (1 / sqrt (fromIntegral i)) * unifRands
      Xavier      -> (sqrt 6 / sqrt (fromIntegral i + fromIntegral o)) * unifRands
      HeEtAl      -> sqrt (2 / fromIntegral i) * gaussRands
  where
    nr = fromIntegral $ natVal (Proxy :: Proxy (n * r))
