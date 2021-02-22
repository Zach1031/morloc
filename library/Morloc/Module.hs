{-|
Module      : Module
Description : Morloc module imports and paths 
Copyright   : (c) Zebulun Arendsee, 2020
License     : GPL-3
Maintainer  : zbwrnz@gmail.com
Stability   : experimental
-}
module Morloc.Module
  ( ModuleSource(..)
  , installModule
  , findModule
  , loadModuleMetadata
  , handleFlagsAndPaths
  ) where

import Morloc.Namespace
import Morloc.Data.Doc
import qualified Data.Char as DC
import qualified Morloc.Config as Config
import qualified Morloc.Data.Text as MT
import qualified Morloc.Monad as MM
import qualified Morloc.System as MS

import Data.Aeson (FromJSON(..), (.!=), (.:?), withObject)
import qualified Data.Yaml.Config as YC

instance FromJSON PackageMeta where
  parseJSON = withObject "object" $ \o ->
    PackageMeta <$> o .:? "name"        .!= ""
                <*> o .:? "version"     .!= ""
                <*> o .:? "homepage"    .!= ""
                <*> o .:? "synopsis"    .!= ""
                <*> o .:? "description" .!= ""
                <*> o .:? "category"    .!= ""
                <*> o .:? "license"     .!= ""
                <*> o .:? "author"      .!= ""
                <*> o .:? "maintainer"  .!= ""
                <*> o .:? "github"      .!= ""
                <*> o .:? "bug-reports" .!= ""
                <*> o .:? "gcc-flags"   .!= ""

-- | Specify where a module is located 
data ModuleSource
  = LocalModule (Maybe MT.Text)
  -- ^ A module in the working directory
  | GithubRepo MT.Text
  -- ^ A module stored in an arbitrary Github repo: "<username>/<reponame>"
  | CoreGithubRepo MT.Text
  -- ^ The repo name of a core package, e.g., "math"

-- | Look for a local morloc module.
findModule :: MVar -> MorlocMonad Path
findModule moduleName = do
  config <- MM.ask
  let lib = Config.configLibrary config
  let allPaths = getModulePaths lib moduleName
  existingPaths <- liftIO . fmap catMaybes . mapM getFile $ allPaths
  case existingPaths of
    (x:_) -> return x
    [] ->
      MM.throwError . CannotLoadModule . render $
        "module not found among the paths:" <+> list (map pretty allPaths)

-- | Give a module path (e.g. "/your/path/foo.loc") find the package metadata.
-- It currently only looks for a file named "package.yaml" in the same folder
-- as the main "*.loc" file. 
findModuleMetadata :: Path -> IO (Maybe Path)
findModuleMetadata mainFile =
  getFile $ MS.combine (MS.takeDirectory mainFile) (Path "package.yaml")

loadModuleMetadata :: Path -> MorlocMonad ()
loadModuleMetadata main = do
  maybef <- liftIO $ findModuleMetadata main
  meta <-
    case maybef of
      (Just f) -> liftIO $ YC.loadYamlSettings [MT.unpack . unPath $ f] [] YC.ignoreEnv
      Nothing -> return defaultPackageMeta
  state <- MM.get
  MM.put (appendMeta meta state)
  where
    appendMeta :: PackageMeta -> MorlocState -> MorlocState
    appendMeta m s = s {statePackageMeta = m : (statePackageMeta s)}

-- | Find an ordered list of possible locations to search for a module
getModulePaths :: Path -> MVar -> [Path]
getModulePaths (Path lib) (MVar base) = map Path
  [ base <> ".loc"                              -- "./${base}.loc"
  , base <> "/" <> "main.loc"                   -- "${base}/main.loc"
  , lib <> "/" <> base <> ".loc"                -- "${LIB}/${base}.loc"
  , lib <> "/" <> base <> "/" <> "main.loc"     -- "${LIB}/${base}/main.loc"
  , lib <> "/" <> base <> "/" <> base <> ".loc" -- "${LIB}/${base}/${base}.loc"
  ]

getHeaderPaths :: Path -> MT.Text -> [MT.Text] -> [Path]
getHeaderPaths (Path lib) header exts = [Path (base <> ext) | base <- bases, ext <- exts]
  where
    bases = [ header                          -- "${header}"
            , "include" <> "/" <> header      -- "${PWD}/include/${header}"
            , "src" <> "/" <> header          -- "${PWD}/src/${header}"
            , lib <> "/" <> header            -- "${INCLUDE}/${header}"
            , "/usr/include/" <> header       -- "/usr/include/${header}"
            , "/usr/local/include/" <> header -- "/usr/local/include/${header}"
            ]

getLibraryPaths :: Path -> MT.Text -> [Path]
getLibraryPaths (Path lib) library = map Path
  [ library                       -- "${library}"
  , "bin" <> "/" <> library       -- "${PWD}/include/${library}"
  , "src" <> "/" <> library       -- "${PWD}/src/${library}"
  , lib <> "/" <> library         -- "${INCLUDE}/${library}"
  , "/usr/bin/" <> library        -- "/usr/include/${library}"
  , "/usr/local/bin/" <> library  -- "/usr/local/include/${library}"
  ]

makeFlagsForSharedLibraries :: Lang -> Source -> Maybe MDoc
makeFlagsForSharedLibraries = undefined

handleFlagsAndPaths :: Lang -> [Source] -> MorlocMonad ([Source], [MT.Text], [Path])
handleFlagsAndPaths CppLang srcs = do
  state <- MM.get
  let gccflags = filter (/= "") . map packageGccFlags $ statePackageMeta state
  
  (srcs', libflags, paths) <-
      fmap unzip3
    . mapM flagAndPath
    . unique
    $ [s | s <- srcs, srcLang s == CppLang]

  return ( filter (isJust . srcPath) srcs' -- all sources that have a defined path (import something)
         , gccflags ++ concat libflags     -- compiler flags and shared libraries
         , unique (catMaybes paths)        -- paths to files to include
         )
handleFlagsAndPaths _ srcs = return (srcs, [], [])

flagAndPath :: Source -> MorlocMonad (Source, [MT.Text], Maybe Path)
flagAndPath src@(Source _ CppLang (Just p) _)
  = case (MS.takeDirectory p, MS.dropExtensions (MS.takeFileName p), MS.takeExtensions p) of
    -- lookup up "<base>.h" and "lib<base>.so"
    (Path ".", base, "") -> do
      header <- lookupHeader base
      libFlags <- lookupLib base
      return (src {srcPath = Just header}, libFlags, Just (MS.takeDirectory header))
    -- use "<base>.h" and lookup "lib<base>.so"
    (dir, base, ext) -> do
      libFlags <- lookupLib base
      return (src, libFlags, Just dir)
  where
    lookupHeader :: MT.Text -> MorlocMonad Path
    lookupHeader base = do
      home <- MM.asks configHome
      let allPaths = getHeaderPaths home base [".h", ".hpp", ".hxx"]
      existingPaths <- liftIO . fmap catMaybes . mapM getFile $ allPaths
      case existingPaths of
        (x:_) -> return x
        [] -> MM.throwError . OtherError $ "Header file " <> base <> ".* not found"


    lookupLib :: MT.Text -> MorlocMonad [MT.Text]
    lookupLib base = do
      home <- MM.asks configHome
      let libnamebase = MT.filter DC.isAlphaNum (MT.toLower base)
      let libname = "lib" <> libnamebase <> ".so"
      let allPaths = getLibraryPaths home libname
      existingPaths <- liftIO . fmap catMaybes . mapM getFile $ allPaths
      case existingPaths of
        (libpath:_) -> do
          libdir <- fmap unPath . liftIO . MS.canonicalizePath . MS.takeDirectory $ libpath
          return
            [ "-Wl,-rpath=" <> libdir
            , "-L" <> libdir
            , "-l" <> libnamebase
            ]
        [] -> return []
flagAndPath src@(Source _ CppLang Nothing _) = return (src, [], Nothing)
flagAndPath (Source _ _ _ _) = MM.throwError . OtherError $ "flagAndPath should only be called for C++ functions"


getFile :: Path -> IO (Maybe Path)
getFile x = do
  exists <- MS.fileExists x
  return $
    if exists
      then Just x
      else Nothing

-- | Attempt to clone a package from github
installGithubRepo ::
     MT.Text -- ^ the repo path ("<username>/<reponame>")
  -> MT.Text -- ^ the url for github (e.g., "https://github.com/")
  -> MorlocMonad ()
installGithubRepo repo url = do
  config <- MM.ask
  let (Path lib) = Config.configLibrary config
  let cmd = MT.unwords ["git clone", url, lib <> "/" <> repo]
  MM.runCommand "installGithubRepo" cmd

-- | Install a morloc module
installModule :: ModuleSource -> MorlocMonad ()
installModule (GithubRepo repo) =
  installGithubRepo repo ("https://github.com/" <> repo)
installModule (CoreGithubRepo name) =
  installGithubRepo name ("https://github.com/morloclib/" <> name)
installModule (LocalModule Nothing) =
  MM.throwError (NotImplemented "module installation from working directory")
installModule (LocalModule (Just _)) =
  MM.throwError (NotImplemented "module installation from local directory")
