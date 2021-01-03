{-# OPTIONS_GHC -fplugin GHC.TypeLits.KnownNat.Solver #-}

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE OverloadedStrings     #-}
{-|
Module      : Grenade.Layers.Reshape
Description : Multipurpose reshaping layer
Copyright   : (c) Huw Campbell, 2016-2017
License     : BSD2
Stability   : experimental
-}
module Grenade.Layers.Reshape
  ( Reshape(..)
  ) where

import           Control.DeepSeq                (NFData (..))
import           Data.Serialize
import           GHC.Generics                   (Generic)
import           GHC.TypeLits
import           Numeric.LinearAlgebra.Data     as LA (flatten)
import           Numeric.LinearAlgebra.Static

import           Grenade.Core

import           Grenade.Onnx

-- | Reshape Layer
--
-- The Reshape layer can flatten any 2D or 3D image to 1D vector with the
-- same number of activations, as well as cast up from 1D to a 2D or 3D
-- shape.
--
-- Can also be used to turn a 3D image with only one channel into a 2D image
-- or vice versa.
data Reshape = Reshape
  deriving (Show,Generic,NFData)

instance UpdateLayer Reshape where
  type Gradient Reshape = ()
  runUpdate _ _ _ = Reshape
  reduceGradient _ = ()

instance RandomLayer Reshape where
  createRandomWith _ _ = return Reshape

instance (KnownNat a, KnownNat x, KnownNat y, a ~ (x * y)) => Layer Reshape ('D2 x y) ('D1 a) where
  type Tape Reshape ('D2 x y) ('D1 a) = ()
  runForwards _ (S2D y)   =  ((), fromJust' . fromStorable . flatten . extract $ y)
  runBackwards _ _ (S1D y) = ((), fromJust' . fromStorable . extract $ y)

instance (KnownNat a, KnownNat x, KnownNat y, KnownNat (x * z), KnownNat z, a ~ (x * y * z)) => Layer Reshape ('D3 x y z) ('D1 a) where
  type Tape Reshape ('D3 x y z) ('D1 a) = ()
  runForwards _ (S3D y)     = ((), fromJust' . fromStorable . flatten . extract $ y)
  runBackwards _ _ (S1D y) = ((), fromJust' . fromStorable . extract $ y)

instance (KnownNat y, KnownNat x, KnownNat z, z ~ 1) => Layer Reshape ('D3 x y z) ('D2 x y) where
  type Tape Reshape ('D3 x y z) ('D2 x y) = ()
  runForwards _ (S3D y)    = ((), S2D y)
  runBackwards _ _ (S2D y) = ((), S3D y)

instance (KnownNat y, KnownNat x, KnownNat z, z ~ 1) => Layer Reshape ('D2 x y) ('D3 x y z) where
  type Tape Reshape ('D2 x y) ('D3 x y z) = ()
  runForwards _ (S2D y)    = ((), S3D y)
  runBackwards _ _ (S3D y) = ((), S2D y)

instance (KnownNat a, KnownNat x, KnownNat y, a ~ (x * y)) => Layer Reshape ('D1 a) ('D2 x y) where
  type Tape Reshape ('D1 a) ('D2 x y) = ()
  runForwards _ (S1D y)   =  ((), fromJust' . fromStorable . extract $ y)
  runBackwards _ _ (S2D y) = ((), fromJust' . fromStorable . flatten . extract $ y)

instance (KnownNat a, KnownNat x, KnownNat y, KnownNat (x * z), KnownNat z, a ~ (x * y * z)) => Layer Reshape ('D1 a) ('D3 x y z) where
  type Tape Reshape ('D1 a) ('D3 x y z) = ()
  runForwards _ (S1D y)     = ((), fromJust' . fromStorable . extract $ y)
  runBackwards _ _ (S3D y)  = ((), fromJust' . fromStorable . flatten . extract $ y)

instance (KnownNat a, KnownNat b, KnownNat c, KnownNat w, KnownNat x, KnownNat y, KnownNat z, (a * b * c) ~ (w * x * y * z)) => Layer Reshape ('D3 a b c) ('D4 w x y z) where
  type Tape Reshape ('D3 a b c) ('D4 w x y z) = ()
  runForwards _ (S3D y)     = ((), fromJust' . fromStorable . flatten . extract $ y)
  runBackwards _ _ (S4D y)  = ((), fromJust' . fromStorable . flatten . extract $ y)

instance (KnownNat a, KnownNat b, KnownNat c, KnownNat d, KnownNat x, KnownNat y, KnownNat z, (a * b * c * d) ~ (x * y * z)) => Layer Reshape ('D4 a b c d) ('D3 x y z) where
  type Tape Reshape ('D4 a b c d) ('D3 x y z) = ()
  runForwards _ (S4D y)     = ((), fromJust' . fromStorable . flatten . extract $ y)
  runBackwards _ _ (S3D y)  = ((), fromJust' . fromStorable . flatten . extract $ y)

instance Serialize Reshape where
  put _ = return ()
  get = return Reshape

fromJust' :: Maybe x -> x
fromJust' (Just x) = x
fromJust' Nothing  = error "Reshape error: data shape couldn't be converted."

instance OnnxOperator Reshape where
  onnxOpTypeNames _ = ["Flatten", "Reshape"]

instance OnnxLoadableActivation Reshape where
  activationLayer = Reshape
