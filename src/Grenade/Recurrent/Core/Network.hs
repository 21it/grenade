{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE CPP                   #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE EmptyDataDecls        #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}

module Grenade.Recurrent.Core.Network (
    Recurrent
  , FeedForward

  , RecurrentNetwork (..)
  , RecurrentInputs (..)
  , RecurrentTape (..)
  , RecurrentGradient (..)

  , randomRecurrent
  , randomRecurrentInitWith
  , runRecurrent
  , runRecurrent'
  , applyRecurrentUpdate
  ) where


import           Control.Monad.Primitive      (PrimBase, PrimState)
import           System.Random.MWC

import           Data.Serialize
import           Data.Singletons              (SingI)
import           Prelude.Singletons      (Head, Last)

#if MIN_VERSION_base(4,9,0)
import           Data.Kind                    (Type)
#endif

import           Grenade.Core
import           Grenade.Recurrent.Core.Layer

-- | Witness type to say indicate we're building up with a normal feed
--   forward layer.
data FeedForward :: Type -> Type
-- | Witness type to say indicate we're building up with a recurrent layer.
data Recurrent :: Type -> Type

-- | Type of a recurrent neural network.
--
--   The [Type] type specifies the types of the layers.
--
--   The [Shape] type specifies the shapes of data passed between the layers.
--
--   The definition is similar to a Network, but every layer in the
--   type is tagged by whether it's a FeedForward Layer of a Recurrent layer.
--
--   Often, to make the definitions more concise, one will use a type alias
--   for these empty data types.
data RecurrentNetwork :: [Type] -> [Shape] -> Type where
  RNil   :: SingI i
         => RecurrentNetwork '[] '[i]

  (:~~>) :: (SingI i, Layer x i h)
         => !x
         -> !(RecurrentNetwork xs (h ': hs))
         -> RecurrentNetwork (FeedForward x ': xs) (i ': h ': hs)

  (:~@>) :: (SingI i, RecurrentLayer x i h)
         => !x
         -> !(RecurrentNetwork xs (h ': hs))
         -> RecurrentNetwork (Recurrent x ': xs) (i ': h ': hs)
infixr 5 :~~>
infixr 5 :~@>

-- | Gradient of a network.
--
--   Parameterised on the layers of the network.
data RecurrentGradient :: [Type] -> Type where
   RGNil  :: RecurrentGradient '[]

   (://>) :: (UpdateLayer x)
          => !(Gradient x)
          -> !(RecurrentGradient xs)
          -> RecurrentGradient (phantom x ': xs)

-- | Recurrent inputs (sideways shapes on an imaginary unrolled graph)
--   Parameterised on the layers of a Network.
data RecurrentInputs :: [Type] -> Type where
   RINil   :: RecurrentInputs '[]

   (:~~+>) :: (UpdateLayer x, Fractional (RecurrentInputs xs))
           => ()                      -> !(RecurrentInputs xs) -> RecurrentInputs (FeedForward x ': xs)

   (:~@+>) :: (Fractional (RecurrentShape x), Fractional (RecurrentInputs xs), RecurrentUpdateLayer x)
           => !(RecurrentShape x) -> !(RecurrentInputs xs) -> RecurrentInputs (Recurrent x ': xs)

-- | All the information required to backpropogate
--   through time safely.
--
--   We index on the time step length as well, to ensure
--   that that all Tape lengths are the same.
data RecurrentTape :: [Type] -> [Shape] -> Type where
   TRNil  :: SingI i
          => RecurrentTape '[] '[i]

   (:\~>) :: Tape x i h
          -> !(RecurrentTape xs (h ': hs))
          -> RecurrentTape (FeedForward x ': xs) (i ': h ': hs)

   (:\@>) :: RecTape x i h
          -> !(RecurrentTape xs (h ': hs))
          -> RecurrentTape (Recurrent x ': xs) (i ': h ': hs)


runRecurrent :: forall shapes layers.
                RecurrentNetwork layers shapes
             -> RecurrentInputs layers
             -> S (Head shapes)
             -> (RecurrentTape layers shapes, RecurrentInputs layers, S (Last shapes))
runRecurrent =
  go
    where
  go  :: forall js sublayers. (Last js ~ Last shapes)
      => RecurrentNetwork sublayers js
      -> RecurrentInputs sublayers
      -> S (Head js)
      -> (RecurrentTape sublayers js, RecurrentInputs sublayers, S (Last js))
  go (!layer :~~> n) (() :~~+> nIn) !x
      = let (!tape, !forwards) = runForwards layer x

            -- recursively run the rest of the network, and get the gradients from above.
            (!newFN, !ig, !answer) = go n nIn forwards
        in (tape :\~> newFN, () :~~+> ig, answer)

  -- This is a recurrent layer, so we need to do a scan, first input to last, providing
  -- the recurrent shape output to the next layer.
  go (layer :~@> n) (recIn :~@+> nIn) !x
      = let (tape, shape, forwards) = runRecurrentForwards layer recIn x
            (newFN, ig, answer) = go n nIn forwards
        in (tape :\@> newFN, shape :~@+> ig, answer)

  -- Handle the output layer, bouncing the derivatives back down.
  -- We may not have a target for each example, so when we don't use 0 gradient.
  go RNil RINil !x
    = (TRNil, RINil, x)

runRecurrent' :: forall layers shapes.
                 RecurrentNetwork layers shapes
              -> RecurrentTape layers shapes
              -> RecurrentInputs layers
              -> S (Last shapes)
              -> (RecurrentGradient layers, RecurrentInputs layers, S (Head shapes))
runRecurrent' net tapes r o =
  go net tapes r
    where
  -- We have to be careful regarding the direction of the lists
  -- Inputs come in forwards, but our return value is backwards
  -- through time.
  go  :: forall js ss. (Last js ~ Last shapes)
      => RecurrentNetwork ss js
      -> RecurrentTape ss js
      -> RecurrentInputs ss
      -> (RecurrentGradient ss, RecurrentInputs ss, S (Head js))
  -- This is a simple non-recurrent layer
  -- Run the rest of the network, update with the tapes and gradients
  go (!layer :~~> n) (!tape :\~> nTapes) (() :~~+> nRecs) =
    let (!gradients, !rins, !feed)  = go n nTapes nRecs
        (!grad, !back)              = runBackwards layer tape feed
    in  (grad ://> gradients, () :~~+> rins, back)

  -- This is a recurrent layer
  -- Run the rest of the network, scan over the tapes in reverse
  go (!layer :~@> n) (!tape :\@> nTapes) (!recGrad :~@+> nRecs) =
    let (!gradients, !rins, !feed)    = go n nTapes nRecs
        (!grad, !sidegrad, !back)     = runRecurrentBackwards layer tape recGrad feed
    in  (grad ://> gradients, sidegrad :~@+> rins, back)

  -- End of the road, so we reflect the given gradients backwards.
  -- Crucially, we reverse the list, so it's backwards in time as
  -- well.
  go !RNil !TRNil !RINil
    = (RGNil, RINil, o)

-- | Apply a batch of gradients to the network
--   Uses runUpdates which can be specialised for
--   a layer.
applyRecurrentUpdate :: Optimizer opt
                     -> RecurrentNetwork layers shapes
                     -> RecurrentGradient layers
                     -> RecurrentNetwork layers shapes
applyRecurrentUpdate opt (layer :~~> rest) (gradient ://> grest)
  = runUpdate opt layer gradient :~~> applyRecurrentUpdate opt rest grest

applyRecurrentUpdate opt (layer :~@> rest) (gradient ://> grest)
  = runUpdate opt layer gradient :~@> applyRecurrentUpdate opt rest grest

applyRecurrentUpdate _ RNil RGNil
  = RNil


instance Show (RecurrentNetwork '[] '[i]) where
  show RNil = "NNil"
instance (Show x, Show (RecurrentNetwork xs rs)) => Show (RecurrentNetwork (FeedForward x ': xs) (i ': rs)) where
  show (x :~~> xs) = show x ++ "\n~~>\n" ++ show xs
instance (Show x, Show (RecurrentNetwork xs rs)) => Show (RecurrentNetwork (Recurrent x ': xs) (i ': rs)) where
  show (x :~@> xs) = show x ++ "\n~~>\n" ++ show xs


-- | A network can easily be created by hand with (:~~>) and (:~@>), but an easy way to initialise a random
--   recurrent network and a set of random inputs for it is with the randomRecurrent.
class CreatableRecurrent (xs :: [Type]) (ss :: [Shape]) where
  -- | Create a network of the types requested
  randomRecurrentWith :: PrimBase m => WeightInitMethod -> Gen (PrimState m) -> m (RecurrentNetwork xs ss)

-- | Create a random recurrent network using uniform distribution.
randomRecurrent :: (CreatableRecurrent xs ss) => IO (RecurrentNetwork xs ss)
randomRecurrent = withSystemRandom . asGenST $ \gen -> randomRecurrentWith UniformInit gen

-- | Create a random recurrent network using the specified weight initialization method.
randomRecurrentInitWith :: (CreatableRecurrent xs ss) => WeightInitMethod -> IO (RecurrentNetwork xs ss)
randomRecurrentInitWith m = withSystemRandom . asGenST $ \gen -> randomRecurrentWith m gen


instance SingI i => CreatableRecurrent '[] '[i] where
  randomRecurrentWith _ _ =
    return RNil

instance (SingI i, Layer x i o, CreatableRecurrent xs (o ': rs), RandomLayer x) => CreatableRecurrent (FeedForward x ': xs) (i ': o ': rs) where
  randomRecurrentWith m gen = do
    thisLayer     <- createRandomWith m gen
    rest          <- randomRecurrentWith m gen
    return (thisLayer :~~> rest)

instance (SingI i, RecurrentLayer x i o, CreatableRecurrent xs (o ':  rs), RandomLayer x) => CreatableRecurrent (Recurrent x ': xs) (i ': o ': rs) where
  randomRecurrentWith m gen = do
    thisLayer     <- createRandomWith m gen
    rest          <- randomRecurrentWith m gen
    return (thisLayer :~@> rest)

-- | Add very simple serialisation to the recurrent network
instance SingI i => Serialize (RecurrentNetwork '[] '[i]) where
  put RNil = pure ()
  get = pure RNil

instance (SingI i, Layer x i o, Serialize x, Serialize (RecurrentNetwork xs (o ': rs))) => Serialize (RecurrentNetwork (FeedForward x ': xs) (i ': o ': rs)) where
  put (x :~~> r) = put x >> put r
  get = (:~~>) <$> get <*> get

instance (SingI i, RecurrentLayer x i o, Serialize x, Serialize (RecurrentNetwork xs (o ': rs))) => Serialize (RecurrentNetwork (Recurrent x ': xs) (i ': o ': rs)) where
  put (x :~@> r) = put x >> put r
  get = (:~@>) <$> get <*> get

instance (Serialize (RecurrentInputs '[])) where
  put _ = return ()
  get = return RINil

instance (UpdateLayer x, Serialize (RecurrentInputs ys), Fractional (RecurrentInputs ys)) => (Serialize (RecurrentInputs (FeedForward x ': ys))) where
  put ( () :~~+> rest) = put rest
  get = ( () :~~+> ) <$> get

instance (Serialize (RecurrentShape x), Fractional (RecurrentShape x), RecurrentUpdateLayer x, Serialize (RecurrentInputs ys), Fractional (RecurrentInputs ys)) => (Serialize (RecurrentInputs (Recurrent x ': ys))) where
  put ( i :~@+> rest ) = put i >> put rest
  get = (:~@+>) <$> get <*> get


-- Num instance for `RecurrentInputs layers`
-- Not sure if this is really needed, as I only need a `fromInteger 0` at
-- the moment for training, to create a null gradient on the recurrent
-- edge.
--
-- It does raise an interesting question though? Is a 0 gradient actually
-- the best?
--
-- I could imaging that weakly push back towards the optimum input could
-- help make a more stable generator.
instance (Num (RecurrentInputs '[])) where
  (+) _ _  = RINil
  (-) _ _  = RINil
  (*) _ _  = RINil
  abs _    = RINil
  signum _ = RINil
  fromInteger _ = RINil

instance (UpdateLayer x, Fractional (RecurrentInputs ys)) => (Num (RecurrentInputs (FeedForward x ': ys))) where
  (+) (() :~~+> x) (() :~~+> y)  = () :~~+> (x + y)
  (-) (() :~~+> x) (() :~~+> y)  = () :~~+> (x - y)
  (*) (() :~~+> x) (() :~~+> y)  = () :~~+> (x * y)
  abs (() :~~+> x)      = () :~~+> abs x
  signum (() :~~+> x)   = () :~~+> signum x
  fromInteger x         = () :~~+> fromInteger x

instance (Fractional (RecurrentShape x), RecurrentUpdateLayer x, Fractional (RecurrentInputs ys)) => (Num (RecurrentInputs (Recurrent x ': ys))) where
  (+) (x :~@+> x') (y :~@+> y')  = (x + y) :~@+> (x' + y')
  (-) (x :~@+> x') (y :~@+> y')  = (x - y) :~@+> (x' - y')
  (*) (x :~@+> x') (y :~@+> y')  = (x * y) :~@+> (x' * y')
  abs (x :~@+> x')      = abs x :~@+> abs x'
  signum (x :~@+> x')   = signum x :~@+> signum x'
  fromInteger x         = fromInteger x :~@+> fromInteger x

instance (Fractional (RecurrentInputs '[])) where
  (/) _ _        = RINil
  recip _        = RINil
  fromRational _ = RINil

instance (UpdateLayer x, Fractional (RecurrentInputs ys)) => (Fractional (RecurrentInputs (FeedForward x ': ys))) where
  (/) (() :~~+> x) (() :~~+> y)  = () :~~+> (x / y)
  recip (() :~~+> x)    = () :~~+> recip x
  fromRational x        = () :~~+> fromRational x

instance (Fractional (RecurrentShape x), RecurrentUpdateLayer x, Fractional (RecurrentInputs ys)) => (Fractional (RecurrentInputs (Recurrent x ': ys))) where
  (/) (x :~@+> x') (y :~@+> y') = (x / y) :~@+> (x' / y')
  recip (x :~@+> x')    = recip x :~@+> recip x'
  fromRational x        = fromRational x :~@+> fromRational x


-- | Ultimate composition.
--
--   This allows a complete network to be treated as a layer in a larger network.
instance CreatableRecurrent sublayers subshapes => UpdateLayer (RecurrentNetwork sublayers subshapes) where
  type Gradient (RecurrentNetwork sublayers subshapes) = RecurrentGradient sublayers
  runUpdate      = applyRecurrentUpdate
  reduceGradient = error "Attempt to reduce gradient of batch in RecurrentNetwork instance"

instance CreatableRecurrent sublayers subshapes => RandomLayer (RecurrentNetwork sublayers subshapes) where
  createRandomWith = randomRecurrentWith

-- | Ultimate composition.
--
--   This allows a complete network to be treated as a layer in a larger network.
instance CreatableRecurrent sublayers subshapes => RecurrentUpdateLayer (RecurrentNetwork sublayers subshapes) where
  type RecurrentShape (RecurrentNetwork sublayers subshapes) = RecurrentInputs sublayers

-- | Ultimate composition.
--
--   This allows a complete network to be treated as a layer in a larger network.
instance ( CreatableRecurrent sublayers subshapes
         , i ~ (Head subshapes), o ~ (Last subshapes)
         , Num (RecurrentShape (RecurrentNetwork sublayers subshapes))
         ) => RecurrentLayer (RecurrentNetwork sublayers subshapes) i o where
  type RecTape (RecurrentNetwork sublayers subshapes) i o = RecurrentTape sublayers subshapes
  runRecurrentForwards = runRecurrent
  runRecurrentBackwards = runRecurrent'
