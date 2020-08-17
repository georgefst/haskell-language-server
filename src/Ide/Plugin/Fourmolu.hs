{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PackageImports      #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module Ide.Plugin.Fourmolu
  (
    descriptor
  , provider
  )
where

import           Control.Exception
import qualified Data.Text                         as T
import           Development.IDE.Core.Rules
import           Development.IDE.Core.RuleTypes    (GhcSession (GhcSession))
import           Development.IDE.Core.Shake        (use)
import           Development.IDE.GHC.Util          (hscEnv)
import           Development.IDE.Types.Diagnostics as D
import           Development.IDE.Types.Location
import qualified DynFlags                          as D
import qualified EnumSet                           as S
import           GHC
import           GHC.LanguageExtensions.Type
import           GhcPlugins                        (HscEnv (hsc_dflags))
import           Ide.Plugin.Formatter
import           Ide.PluginUtils
import           Ide.Types
import           Language.Haskell.LSP.Core         (LspFuncs (withIndefiniteProgress),
                                                    ProgressCancellable (Cancellable))
import           Language.Haskell.LSP.Types
import "fourmolu" Ormolu
import           System.FilePath                   (takeFileName)
import           Text.Regex.TDFA.Text              ()

-- ---------------------------------------------------------------------

descriptor :: PluginId -> PluginDescriptor
descriptor plId = (defaultPluginDescriptor plId)
  { pluginFormattingProvider = Just provider
  }

-- ---------------------------------------------------------------------

provider :: FormattingProvider IO
provider lf ideState typ contents fp _ = withIndefiniteProgress lf title Cancellable $ do
  let
    fromDyn :: DynFlags -> IO [DynOption]
    fromDyn df =
      let
        pp =
          let p = D.sPgm_F $ D.settings df
          in  if null p then [] else ["-pgmF=" <> p]
        pm = map (("-fplugin=" <>) . moduleNameString) $ D.pluginModNames df
        ex = map showExtension $ S.toList $ D.extensionFlags df
      in
        return $ map DynOption $ pp <> pm <> ex

  ghc <- runAction "Fourmolu" ideState $ use GhcSession fp
  let df = hsc_dflags . hscEnv <$> ghc
  fileOpts <- case df of
          Nothing -> return []
          Just df -> fromDyn df

  let
    fullRegion = RegionIndices Nothing Nothing
    rangeRegion s e = RegionIndices (Just $ s + 1) (Just $ e + 1)
    mkConf o region = do
      filePrinterOpts <- loadConfigFile True $ Just fp'
      return defaultConfig
        { cfgDynOptions = o
        , cfgRegion = region
        , cfgDebug = True
        , cfgPrinterOpts = fillMissingPrinterOpts filePrinterOpts defaultPrinterOpts
        }
    fmt :: T.Text -> Config RegionIndices -> IO (Either OrmoluException T.Text)
    fmt cont conf =
      try @OrmoluException (ormolu conf fp' $ T.unpack cont)
    fp' = fromNormalizedFilePath fp

  case typ of
    FormatText -> ret <$> (fmt contents =<< mkConf fileOpts fullRegion)
    FormatRange (Range (Position sl _) (Position el _)) ->
      ret <$> (fmt contents =<< mkConf fileOpts (rangeRegion sl el))
 where
  title = T.pack $ "Formatting " <> takeFileName (fromNormalizedFilePath fp)
  ret :: Either OrmoluException T.Text -> Either ResponseError (List TextEdit)
  ret (Left err) = Left
    (responseError (T.pack $ "fourmoluCmd: " ++ show err) )
  ret (Right new) = Right (makeDiffTextEdit contents new)

showExtension :: Extension -> String
showExtension Cpp   = "-XCPP"
showExtension other = "-X" ++ show other
