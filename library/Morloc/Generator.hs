{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Morloc.Generator
Description : Generate code from the RDF representation of a Morloc script 
Copyright   : (c) Zebulun Arendsee, 2018
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}

module Morloc.Generator
(
    Nexus
  , Pool
  , generate  
) where

import Morloc.Global
import qualified Morloc.Language as ML
import qualified Morloc.Nexus.Nexus as MN
import qualified Morloc.Pools.Pools as MP

type Nexus = Script
type Pool  = Script

-- | Given a SPARQL endpoint, generate an executable program
generate :: SparqlDatabaseLike db => db -> MorlocMonad (Nexus, [Pool])
generate e = (,) <$> (MN.generate ML.PerlLang e) <*> (MP.generate e)
