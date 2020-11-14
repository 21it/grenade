{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE PolyKinds #-}

module Grenade.Onnx.Graph 
  ( readInitializerMatrix
  , readInitializerVector
  , readIntsAttribute
  , readDoubleAttribute
  , doesNotHaveAttribute
  )
  where

import Data.ProtoLens.Labels ()
import qualified Proto.Onnx as P
import Lens.Micro
import qualified Data.Text as T
import Data.Maybe (isNothing, listToMaybe)

import           Control.Monad (guard)
import qualified Data.Map.Strict                as Map
import           Data.Proxy
import           GHC.TypeLits
import           GHC.Float (float2Double)
import           Numeric.LinearAlgebra.Static

readAttribute :: T.Text -> P.NodeProto -> Maybe P.AttributeProto
readAttribute attribute node = listToMaybe $ filter ((== attribute) . (^. #name)) $ node ^. #attribute

readDoubleAttribute :: T.Text -> P.NodeProto -> Maybe Double
readDoubleAttribute attribute node = readAttribute attribute node >>= retrieve
  where
    retrieve attribute = case (attribute ^. #type') of
                           P.AttributeProto'FLOAT -> Just $ float2Double $ attribute ^. #f
                           _                      -> Nothing

readIntsAttribute :: T.Text -> P.NodeProto -> Maybe [Int]
readIntsAttribute attribute node = readAttribute attribute node >>= retrieve
  where
    retrieve attribute = case (attribute ^. #type') of
                           P.AttributeProto'INTS -> Just $ map fromIntegral $ attribute ^. #ints
                           _                     -> Nothing

doesNotHaveAttribute :: P.NodeProto -> T.Text -> Maybe ()
doesNotHaveAttribute node attribute = guard $ isNothing $ readAttribute attribute node

readInitializer :: Map.Map T.Text P.TensorProto -> T.Text -> Maybe ([Int], [Double])
readInitializer inits name = Map.lookup name inits >>= retrieve
  where 
    retrieve tensor = case toEnum (fromIntegral (tensor ^. #dataType)) of
                        P.TensorProto'FLOAT -> Just (map fromIntegral (tensor ^. #dims), map float2Double (tensor ^. #floatData))
                        _                   -> Nothing

readInitializerMatrix :: (KnownNat r, KnownNat c) => Map.Map T.Text P.TensorProto -> T.Text -> Maybe (L r c)
readInitializerMatrix inits name = readInitializer inits name >>= readMatrix

readInitializerVector :: KnownNat r => Map.Map T.Text P.TensorProto -> T.Text -> Maybe (R r)
readInitializerVector inits name = readInitializer inits name >>= readVector

readMatrix :: forall r c . (KnownNat r, KnownNat c) => ([Int], [Double]) -> Maybe (L r c)
readMatrix (rows : cols, vals)
  | neededRows == rows && neededCols == product cols = Just (matrix vals)
  where
    neededRows = fromIntegral $ natVal (Proxy :: Proxy r)
    neededCols = fromIntegral $ natVal (Proxy :: Proxy c)
readMatrix _ = Nothing

readVector :: forall r . KnownNat r => ([Int], [Double]) -> Maybe (R r)
readVector ([rows], vals)
  | rows == neededRows = Just (vector vals)
  where
    neededRows = fromIntegral $ natVal (Proxy :: Proxy r)
readVector _ = Nothing
