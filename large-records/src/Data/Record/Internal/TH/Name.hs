{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingVia           #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE KindSignatures        #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TypeApplications      #-}

{-# OPTIONS_GHC -Wno-partial-type-signatures #-}

-- | Names with statically known flavour
--
-- Intended for qualified import.
module Data.Record.Internal.TH.Name (
    -- * Names
    Name(..)
  , Flavour(..)
  , NameFlavour(..)
    -- * Simple functions
  , nameBase
  , mapNameBase
    -- * Working with qualified names
  , Qualifier(..)
  , qualify
  , unqualified
  , nameQualifier
    -- * Fresh names
  , newName
    -- * Conversion
  , fromTH
  , fromTH'
  , toTH
    -- * Resolution
  , LookupName(..)
  , reify
    -- * Construct TH
  , classD
  , conE
  , conT
  , newtypeD
  , dataD
  , patSynD
  , patSynSigD
  , pragCompleteD
  , recC
  , recordPatSyn
  , sigD
  , varBangType
  , varE
  , varLocalP
  , varGlobalP
  , conP
  , varLocalT
  , plainLocalTV
  ) where

import Data.Kind
import Data.Maybe (fromMaybe)
import Language.Haskell.TH (Q)
import Language.Haskell.TH.Syntax (Quasi, runQ, NameSpace(..))

import qualified Language.Haskell.TH.Syntax as TH
import qualified Language.Haskell.TH.Lib    as TH

import Data.Record.Internal.TH.Compat

{-------------------------------------------------------------------------------
  Names
-------------------------------------------------------------------------------}

-- | Name flavours (used as a kind, not as a type)
--
-- Technically speaking there is one flavour missing: names that are locally
-- bound, but outside of the TH quote, something like
--
-- > foo x = [| .. x .. |]
--
-- However, we won't actually deal with such names.
data Flavour =
    -- | Dynamically bound
    --
    -- Dynamically bound names will be bound to a global name by @ghc@ after
    -- splicing the TH generated Haskelll code.
    --
    -- These are generated with 'mkName' (also used by @haskell-src-meta@).
    Dynamic

    -- | A new name
    --
    -- These are names either generated by 'newName' or are new names in a TH
    -- declaration quote @[d| ... |]@.
  | Unique

    -- | Reference to a specific name defined outside of the TH quote
  | Global

data NameFlavour :: Flavour -> Type where
  -- | Dynamically bound name, with an optional module prefix (@T.foo@)
  NameDynamic :: Maybe TH.ModName -> NameFlavour 'Dynamic

  -- | Unique local name
  NameUnique :: TH.Uniq -> NameFlavour 'Unique

  -- | Global name bound outside of the TH quot
  NameGlobal :: TH.NameSpace -> TH.PkgName -> TH.ModName -> NameFlavour 'Global

-- | Like TH's 'Name', but with statically known flavour.
data Name :: NameSpace -> Flavour -> Type where
  Name :: TH.OccName -> NameFlavour flavour -> Name ns flavour

deriving instance Show (NameFlavour flavour)
deriving instance Eq   (NameFlavour flavour)
deriving instance Ord  (NameFlavour flavour)

deriving instance Show (Name ns flavour)
deriving instance Eq   (Name ns flavour)
deriving instance Ord  (Name ns flavour)

{-------------------------------------------------------------------------------
  Simple functions
-------------------------------------------------------------------------------}

nameBase :: Name ns flavour -> String
nameBase (Name (TH.OccName occ) _) = occ

-- | Modify the unqualified part of the name
--
-- Since we often to do this derive one kind of name from another, the
-- namespace of the result is not related to the namespace of the argument.
mapNameBase :: (String -> String) -> Name ns flavour -> Name ns' flavour
mapNameBase f (Name (TH.OccName occ) flav) = Name (TH.OccName (f occ)) flav

{-------------------------------------------------------------------------------
  Working with qualified names
-------------------------------------------------------------------------------}

data Qualifier = Unqual | Qual TH.ModName

qualify :: Qualifier -> String -> Name ns 'Dynamic
qualify Unqual   occ = Name (TH.OccName occ) (NameDynamic Nothing)
qualify (Qual m) occ = Name (TH.OccName occ) (NameDynamic (Just m))

unqualified :: String -> Name ns 'Dynamic
unqualified = qualify Unqual

nameQualifier :: Name ns 'Dynamic -> Qualifier
nameQualifier (Name _ (NameDynamic (Just m))) = Qual m
nameQualifier (Name _ (NameDynamic Nothing))  = Unqual

{-------------------------------------------------------------------------------
  Singleton
-------------------------------------------------------------------------------}

-- | Singleton type associated with 'Flavour'
data SFlavour :: Flavour -> Type where
  SDynamic :: SFlavour 'Dynamic
  SUnique  :: SFlavour 'Unique
  SGlobal  :: SFlavour 'Global

deriving instance Show (SFlavour flavour)

class IsFlavour flavour where
  isFlavour :: SFlavour flavour

instance IsFlavour 'Dynamic where isFlavour = SDynamic
instance IsFlavour 'Unique  where isFlavour = SUnique
instance IsFlavour 'Global  where isFlavour = SGlobal

{-------------------------------------------------------------------------------
  Conversion
-------------------------------------------------------------------------------}

toFlavourF :: SFlavour flavour -> TH.NameFlavour -> Maybe (NameFlavour flavour)
toFlavourF SDynamic (TH.NameS)       = Just $ NameDynamic Nothing
toFlavourF SDynamic (TH.NameQ m)     = Just $ NameDynamic (Just m)
toFlavourF SUnique  (TH.NameU u)     = Just $ NameUnique u
toFlavourF SGlobal  (TH.NameG n p m) = Just $ NameGlobal n p m
toFlavourF _        _                = Nothing

fromFlavourF :: NameFlavour flavour -> TH.NameFlavour
fromFlavourF (NameDynamic Nothing)  = TH.NameS
fromFlavourF (NameDynamic (Just m)) = TH.NameQ m
fromFlavourF (NameUnique u)         = TH.NameU u
fromFlavourF (NameGlobal n p m)     = TH.NameG n p m

-- | Translate from a dynamically typed TH name
--
-- Returns 'Nothing' if the TH name does not have the specified flavour.
fromTH :: IsFlavour flavour => TH.Name -> Maybe (Name ns flavour)
fromTH (TH.Name occ flavour') = Name occ <$> toFlavourF isFlavour flavour'

-- | Variation on 'fromTH' that throws an exception on a flavour mismatch
fromTH' :: forall ns flavour. IsFlavour flavour => TH.Name -> Name ns flavour
fromTH' name@(TH.Name occ flavour') =
    fromMaybe (error err) $ fromTH name
  where
    err :: String
    err = concat [
          "fromTH': name "
        , show occ
        , " has the wrong flavour: "
        , show (isFlavour :: SFlavour flavour)
        , " /= "
        , show flavour'
        ]

-- | Forget type level information
toTH :: Name ns flavour -> TH.Name
toTH (Name occ flavour) = TH.Name occ (fromFlavourF flavour)

{-------------------------------------------------------------------------------
  Resolution
-------------------------------------------------------------------------------}

class LookupName ns where
  -- | Resolve existing name
  lookupName :: Quasi m => Name ns 'Dynamic -> m (Maybe (Name ns 'Global))

instance LookupName 'TcClsName where
  lookupName (Name occ (NameDynamic mMod)) =
      fmap fromTH' <$>
        runQ (TH.lookupTypeName $ qualifyDotted mMod occ)

instance LookupName 'DataName where
  lookupName (Name occ (NameDynamic mMod)) =
      fmap fromTH' <$>
        runQ (TH.lookupValueName $ qualifyDotted mMod occ)

instance LookupName 'VarName where
  lookupName (Name occ (NameDynamic mMod)) =
      fmap fromTH' <$>
        runQ (TH.lookupValueName $ qualifyDotted mMod occ)

-- | Get info about the given name
--
-- Only global names can be reified. See 'lookupName'.
reify :: Quasi m => Name ns 'Global -> m TH.Info
reify = runQ . TH.reify . toTH

{-------------------------------------------------------------------------------
  Fresh names
-------------------------------------------------------------------------------}

newName :: String -> Q (Name ns 'Unique)
newName = fmap fromTH' . TH.newName

{-------------------------------------------------------------------------------
  /Defining/ global names

  Since these are all meant to define capturable names, these functions all take
  an 'Dynamic' name as argument.
-------------------------------------------------------------------------------}

-- | Define pattern synonym
patSynD :: Name 'DataName 'Dynamic -> Q _ -> _
patSynD = TH.patSynD . toTH

-- | Define pattern synonym signature
patSynSigD :: Name 'DataName 'Dynamic -> Q _ -> _
patSynSigD = TH.patSynSigD . toTH

-- | Define function signature
sigD :: Name 'VarName 'Dynamic -> Q _ -> _
sigD = TH.sigD . toTH

-- | Define record field signature
varBangType :: Name 'VarName 'Dynamic -> Q _ -> _
varBangType = TH.varBangType . toTH

-- | Define record constructor
recC :: Name 'DataName 'Dynamic -> [Q _] -> _
recC = TH.recC . toTH

-- | Define class
classD :: Q _ -> Name 'TcClsName 'Dynamic -> _
classD cxt = TH.classD cxt . toTH

-- | Define newtype
newtypeD :: Q _ -> Name 'TcClsName 'Dynamic -> _
newtypeD cxt = TH.newtypeD cxt . toTH

-- | Define a datatype
dataD :: Q _ -> Name 'TcClsName 'Dynamic -> _
dataD cxt nm = TH.dataD cxt (toTH nm)

-- | Define record pattern synonym
recordPatSyn :: [String] -> Q _
recordPatSyn = TH.recordPatSyn . map (toTH . unqualified)

-- | Define COMPLETE pragma
pragCompleteD :: [Name 'DataName 'Dynamic] -> Maybe (Name 'TcClsName 'Dynamic) -> Q _
pragCompleteD constrs typ =
    TH.pragCompleteD (toTH <$> constrs) (toTH <$> typ)

-- | Define pattern variable for use in a record pattern synonym
varGlobalP :: Name 'VarName 'Dynamic -> Q _
varGlobalP = TH.varP . toTH

-- | Define pattern variable for use in a local pattern match
varLocalP :: Name 'VarName 'Unique -> Q _
varLocalP = TH.varP . toTH

-- | Constructor pattern
conP :: Name 'DataName 'Dynamic -> [TH.PatQ] -> TH.PatQ
conP = TH.conP . toTH

-- | Reference locally bound type variable
varLocalT :: Name 'VarName 'Unique -> Q _
varLocalT = TH.varT . toTH

-- | Create locally bound type variable
plainLocalTV :: Name 'VarName 'Unique -> TyVarBndr
plainLocalTV = PlainTV . toTH

{-------------------------------------------------------------------------------
  Referencing existing names

  We can reference any flavour of name.
-------------------------------------------------------------------------------}

-- | Reference constructor
conE :: Name 'DataName flavour -> Q _
conE = TH.conE . toTH

-- | Reference type
conT :: Name 'TcClsName flavour -> Q _
conT = TH.conT . toTH

-- | Reference variable
varE :: Name 'VarName flavour -> Q _
varE = TH.varE . toTH

{-------------------------------------------------------------------------------
  Internal auxiliary
-------------------------------------------------------------------------------}

-- | Qualify a name (for use in 'lookupTypeName' and co)
qualifyDotted :: Maybe TH.ModName -> TH.OccName -> String
qualifyDotted Nothing               (TH.OccName occ) = occ
qualifyDotted (Just (TH.ModName m)) (TH.OccName occ) = m ++ "." ++ occ