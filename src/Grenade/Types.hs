{-# LANGUAGE CPP #-}
module Grenade.Types where

import Data.Typeable

#ifdef USE_FLOAT
type RealNum = Float       -- when using the hmatrix-float package
#else
#ifdef USE_DOUBLE
type RealNum = Double   -- when using the hmatrix package
#else
#ifdef FLYCHECK
type RealNum = Double
#else
You have to provide the preprocessor directive (for GHC and GCC) -DUSE_FLOAT or -DUSE_DOUBLE
#endif
#endif
#endif

-- | String representation of type `F`, which is either Float or Double type.
nameF :: String
nameF = show (typeRep (Proxy :: Proxy RealNum))
