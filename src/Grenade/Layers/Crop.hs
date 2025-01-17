{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-|
Module      : Grenade.Layers.Crop
Description : Cropping layer
Copyright   : (c) Huw Campbell, 2016-2017
License     : BSD2
Stability   : experimental
-}
module Grenade.Layers.Crop (
    Crop (..)
  ) where

import           Control.DeepSeq              (NFData)
import           Data.Kind                    (Type)
import           Data.Maybe
import           Data.Proxy
import           Data.Serialize
import           GHC.TypeLits.Singletons     hiding (natVal)
import           GHC.Generics                 (Generic)
import           GHC.TypeLits
import           Numeric.LinearAlgebra        (diagBlock, konst, subMatrix)
import           Numeric.LinearAlgebra.Static (create, extract)

import           Grenade.Core
import           Grenade.Layers.Internal.Pad


-- | A cropping layer for a neural network.
data Crop :: Nat
          -> Nat
          -> Nat
          -> Nat -> Type where
  Crop :: Crop cropLeft cropTop cropRight cropBottom
  deriving (Generic,NFData)

instance Show (Crop cropLeft cropTop cropRight cropBottom) where
  show Crop = "Crop"

instance UpdateLayer (Crop l t r b) where
  type Gradient (Crop l t r b) = ()
  runUpdate _ x _ = x
  reduceGradient _ = ()

instance Serialize (Crop l t r b) where
  put _ = return ()
  get = return Crop

-- | A two dimensional image can be cropped.
instance ( KnownNat cropLeft
         , KnownNat cropTop
         , KnownNat cropRight
         , KnownNat cropBottom
         , KnownNat inputRows
         , KnownNat inputColumns
         , KnownNat outputRows
         , KnownNat outputColumns
         , (outputRows + cropTop + cropBottom) ~ inputRows
         , (outputColumns + cropLeft + cropRight) ~ inputColumns
         ) => Layer (Crop cropLeft cropTop cropRight cropBottom) ('D2 inputRows inputColumns) ('D2 outputRows outputColumns) where
  type Tape (Crop cropLeft cropTop cropRight cropBottom) ('D2 inputRows inputColumns) ('D2 outputRows outputColumns) = ()
  runForwards Crop (S2D input) =
    let cropl = fromIntegral $ natVal (Proxy :: Proxy cropLeft)
        cropt = fromIntegral $ natVal (Proxy :: Proxy cropTop)
        nrows = fromIntegral $ natVal (Proxy :: Proxy outputRows)
        ncols = fromIntegral $ natVal (Proxy :: Proxy outputColumns)
        m  = extract input
        r  = subMatrix (cropt, cropl) (nrows, ncols) m
    in  ((), S2D . fromJust . create $ r)
  runBackwards _ _ (S2D dEdy) =
    let cropl = fromIntegral $ natVal (Proxy :: Proxy cropLeft)
        cropt = fromIntegral $ natVal (Proxy :: Proxy cropTop)
        cropr = fromIntegral $ natVal (Proxy :: Proxy cropRight)
        cropb = fromIntegral $ natVal (Proxy :: Proxy cropBottom)
        eo    = extract dEdy
        vs    = diagBlock [konst 0 (cropt,cropl), eo, konst 0 (cropb,cropr)]
    in  ((), S2D . fromJust . create $ vs)


-- | A three dimensional image can be cropped.
instance ( KnownNat cropLeft
         , KnownNat cropTop
         , KnownNat cropRight
         , KnownNat cropBottom
         , KnownNat inputRows
         , KnownNat inputColumns
         , KnownNat outputRows
         , KnownNat outputColumns
         , KnownNat channels
         , KnownNat (inputRows * channels)
         , KnownNat (outputRows * channels)
         , (outputRows + cropTop + cropBottom) ~ inputRows
         , (outputColumns + cropLeft + cropRight) ~ inputColumns
         ) => Layer (Crop cropLeft cropTop cropRight cropBottom) ('D3 inputRows inputColumns channels) ('D3 outputRows outputColumns channels) where
  type Tape (Crop cropLeft cropTop cropRight cropBottom) ('D3 inputRows inputColumns channels) ('D3 outputRows outputColumns channels)  = ()
  runForwards Crop (S3D input) =
    let padl  = fromIntegral $ natVal (Proxy :: Proxy cropLeft)
        padt  = fromIntegral $ natVal (Proxy :: Proxy cropTop)
        padr  = fromIntegral $ natVal (Proxy :: Proxy cropRight)
        padb  = fromIntegral $ natVal (Proxy :: Proxy cropBottom)
        inr   = fromIntegral $ natVal (Proxy :: Proxy inputRows)
        inc   = fromIntegral $ natVal (Proxy :: Proxy inputColumns)
        outr  = fromIntegral $ natVal (Proxy :: Proxy outputRows)
        outc  = fromIntegral $ natVal (Proxy :: Proxy outputColumns)
        ch    = fromIntegral $ natVal (Proxy :: Proxy channels)
        m     = extract input
        cropped = crop ch padl padt padr padb outr outc inr inc m
    in  ((), S3D . fromJust . create $ cropped)

  runBackwards Crop () (S3D gradient) =
    let padl  = fromIntegral $ natVal (Proxy :: Proxy cropLeft)
        padt  = fromIntegral $ natVal (Proxy :: Proxy cropTop)
        padr  = fromIntegral $ natVal (Proxy :: Proxy cropRight)
        padb  = fromIntegral $ natVal (Proxy :: Proxy cropBottom)
        inr   = fromIntegral $ natVal (Proxy :: Proxy inputRows)
        inc   = fromIntegral $ natVal (Proxy :: Proxy inputColumns)
        outr  = fromIntegral $ natVal (Proxy :: Proxy outputRows)
        outc  = fromIntegral $ natVal (Proxy :: Proxy outputColumns)
        ch    = fromIntegral $ natVal (Proxy :: Proxy channels)
        m     = extract gradient
        padded = pad ch padl padt padr padb outr outc inr inc m
    in  ((), S3D . fromJust . create $ padded)


instance RandomLayer (Crop l t r b) where
  createRandomWith _ _ = return Crop
