{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeOperators              #-}

-- | Canonical gecord (i.e., no diff)
--
-- Intended for qualified import.
--
-- > import Data.Record.Anonymous.Internal.Canonical (Canonical)
-- > import qualified Data.Record.Anonymous.Internal.Canonical as Canon
module Data.Record.Anonymous.Internal.Canonical (
    Canonical(..)
    -- * Indexed access
  , getAtIndex
  , setAtIndex
    -- * Conversion
  , toList
  , fromList
  , toLazyVector
  , fromLazyVector
    -- * Basic API
  , insert
  , project
    -- * Simple (non-constrained) combinators
  , map
  , mapM
  , zipWith
  , zipWithM
  , collapse
  , sequenceA
  , ap
    -- * Debugging support
  , toString
  ) where

import Prelude hiding (map, mapM, zip, zipWith, sequenceA, pure)

import Data.Coerce (coerce)
import Data.SOP.BasicFunctors
import Data.SOP.Classes (type (-.->)(apFn))
import GHC.Exts (Any)

import qualified Data.Vector         as Lazy
import qualified Data.Vector.Generic as V

import Data.Record.Anonymous.Internal.Debugging
import Data.Record.Anonymous.Internal.StrictVector (Vector)

import qualified Data.Record.Anonymous.Internal.StrictVector as Strict

{-------------------------------------------------------------------------------
  Definition
-------------------------------------------------------------------------------}

-- | Canonical record representation
--
-- Canonicity here refers to the fact that we have no @Diff@ to apply
-- (see "Data.Record.Anonymous.Internal.Diff").
--
-- Type level shadowing is reflected at the term level: if a record has
-- duplicate fields in its type, it will have multiple entries for that field
-- in the vector.
--
-- TODO: Currently we have no way of recovering the value of shadowed fields,
-- adding an API for that is future work. The work by Daan Leijen on scoped
-- labels might offer some inspiration there.
--
-- NOTE: When we cite the algorithmic complexity of operations on 'Canonical',
-- we assume that 'HashMap' inserts and lookups are @O(1)@, which they are in
-- practice (especially given the relatively small size of typical records),
-- even if theoretically they are @O(log n)@. See also the documentation of
-- "Data.HashMap.Strict".
newtype Canonical f = Canonical {
      -- | All values in the record, in row order.
      --
      -- It is important that the vector is in row order: this is what makes
      -- it possible to define functions such as @mapM@ (for which ordering
      -- must be well-defined).
      --
      -- NOTE: Since @large-anon@ currently only supports records with strict
      -- fields, we use a strict vector here.
      canonValues :: Vector (f Any)
    }
  deriving newtype (Semigroup, Monoid)

deriving instance Show a => Show (Canonical (K a))

{-------------------------------------------------------------------------------
  Indexed access
-------------------------------------------------------------------------------}

-- | Get field at the specified index
--
-- @O(1)@.
getAtIndex :: Canonical f -> Int -> f Any
getAtIndex Canonical{canonValues} ix = canonValues V.! ix

-- | Set fields at the specified indices
--
-- @O(n)@ in the size of the record (independent of the number of field updates)
-- @O(1)@ if the list of updates is empty.
setAtIndex :: [(Int, f Any)] -> Canonical f -> Canonical f
setAtIndex [] c             = c
setAtIndex fs (Canonical v) = Canonical (v V.// fs)

{-------------------------------------------------------------------------------
  Conversion
-------------------------------------------------------------------------------}

-- | All fields in row order
--
-- @O(n)@
toList :: Canonical f -> [f Any]
toList (Canonical v) = V.toList v

-- | From list of fields in row order
--
-- @O(n)@.
fromList :: [f Any] -> Canonical f
fromList = Canonical . Strict.fromList

-- | To lazy vector
toLazyVector :: Canonical f -> Lazy.Vector (f Any)
toLazyVector = Strict.toLazy . canonValues

-- | From already constructed vector
fromLazyVector :: Lazy.Vector (f Any) -> Canonical f
fromLazyVector = Canonical . Strict.fromLazy

{-------------------------------------------------------------------------------
  Basic API
-------------------------------------------------------------------------------}

-- | Insert fields into the record
--
-- It is the responsibility of the caller to make sure that the linear
-- concatenation of the new fields to the existing record matches the row order
-- of the new record.
--
-- @O(n)@ in the number of inserts and the size of the record.
-- @O(1)@ if the list of inserts is empty.
insert :: forall f. [f Any] -> Canonical f -> Canonical f
insert []  = id
insert new = prepend
  where
     prepend :: Canonical f -> Canonical f
     prepend (Canonical v) = Canonical (Strict.fromList new <> v)

-- | Project out some fields in the selected order
--
-- It is the responsibility of the caller that the list of indices is in row
-- order of the new record.
--
-- @O(n)@.
project :: [Int] -> Canonical f -> Canonical f
project is (Canonical v) = Canonical $ V.backpermute v (Strict.fromList is)

{-------------------------------------------------------------------------------
  Simple (non-constrained) combinators

  NOTE: Some of these have a 'Monad' constraint where one might expect an
  'Applicative' only . The reason is that this allows for better implementations
  in terms of the underlying vector (for example, 'zipWithM' in @base@ merely
  requires an 'Applicative constraint, but on vectors has a 'Monad' constraint).
  Should this turn out to be problematic, we could offer an alternative more
  general but slower set of operators.
-------------------------------------------------------------------------------}

map :: (forall x. f x -> g x) -> Canonical f -> Canonical g
map f (Canonical v) = Canonical $ fmap f v

mapM ::
     Monad m
  => (forall x. f x -> m (g x))
  -> Canonical f -> m (Canonical g)
mapM f (Canonical v) = Canonical <$> Strict.mapM f v

-- | Zip two records
--
-- Precondition: the two records must have the same shape.
zipWith ::
     (forall x. f x -> g x -> h x)
  -> Canonical f -> Canonical g -> Canonical h
zipWith f (Canonical v) (Canonical v') = Canonical $ V.zipWith f v v'

-- | Monadic zip of two records
--
-- Precondition: the two records must have the same shape.
zipWithM ::
     Monad m
  => (forall x. f x -> g x -> m (h x))
  -> Canonical f -> Canonical g -> m (Canonical h)
zipWithM f (Canonical v) (Canonical v') = Canonical <$> V.zipWithM f v v'

collapse :: Canonical (K a) -> [a]
collapse (Canonical v) = co $ V.toList v
  where
    co :: [K a Any] -> [a]
    co = coerce

sequenceA :: Monad m => Canonical (m :.: f) -> m (Canonical f)
sequenceA (Canonical v) = Canonical <$> Strict.mapM unComp v

ap :: Canonical (f -.-> g) -> Canonical f -> Canonical g
ap = zipWith apFn

{-------------------------------------------------------------------------------
  Debugging support
-------------------------------------------------------------------------------}

toString :: Canonical f -> String
toString = show . map (K . ShowViaRecoverRTTI)
