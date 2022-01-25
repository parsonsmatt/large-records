{-# LANGUAGE CPP              #-}
{-# LANGUAGE TypeApplications #-}

#ifdef USE_GHC_DUMP
{-# OPTIONS_GHC -fplugin GhcDump.Plugin #-}
#endif

module Test.Record.Experiments.ToTreeEnum.TE090 where

import Data.Proxy

import Test.Record.Experiments.HList.HL090
import Test.Record.Experiments.ToTreeEnum

requiresInstance :: ()
requiresInstance = requireEmptyClass (Proxy @ExampleFields)