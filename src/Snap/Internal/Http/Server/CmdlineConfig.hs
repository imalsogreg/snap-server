{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
------------------------------------------------------------------------------
-- | This module exports the 'Config' datatype, which you can use to configure
-- the Snap HTTP server.
--
module Snap.Internal.Http.Server.CmdlineConfig
  -- NOTE: also edit Snap.Http.Server.CmdlineConfig if you change these
  ( CmdlineConfigAccessLog(..)
  , CmdlineConfigErrLog(..)
  , CmdlineConfig(..)
  , ProxyType(..)

  , emptyCmdlineConfig
  , defaultCmdlineConfig

  , cmdlineConfig
  , extendedCmdlineConfig

  , optDescrs
  , fmapOpt

  , getAccessLog
  , getBind
  , getCompression
  , getDefaultTimeout
  , getErrorHandler
  , getErrorLog
  , getHostname
  , getLocale
  , getOther
  , getPort
  , getProxyType
  , getSSLBind
  , getSSLCert
  , getSSLChainCert
  , getSSLKey
  , getSSLPort
  , getVerbose
    -- FIXME: remove getStartupHook, replace with something better
  , getStartupHook
  , getUnixSocket
  , getUnixSocketAccessMode

  , setAccessLog
  , setBind
  , setCompression
  , setDefaultTimeout
  , setErrorHandler
  , setErrorLog
  , setHostname
  , setLocale
  , setOther
  , setPort
  , setProxyType
  , setSSLBind
  , setSSLCert
  , setSSLChainCert
  , setSSLKey
  , setSSLPort
  , setVerbose
  , setUnixSocket
  , setUnixSocketAccessMode

  , setStartupHook

  -- TODO: scrap this
  , StartupInfo(..)
  , getStartupSockets
  , getStartupConfig

  -- * Private
  , emptyStartupInfo
  , setStartupSockets
  , setStartupConfig
  ) where

------------------------------------------------------------------------------
import           Control.Exception               (SomeException)
import           Data.Bits                       ((.&.))
import           Data.ByteString                 (ByteString)
import qualified Data.ByteString.Char8           as S
import qualified Data.ByteString.Lazy.Char8      as L
import qualified Data.CaseInsensitive            as CI
import           Data.Function                   (on)
import           Data.List                       (foldl')
#if !MIN_VERSION_base(4,8,0)
import           Data.Monoid                     (Monoid (..))
#endif
import           Data.Monoid                     (Last (Last, getLast))
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as T
#if MIN_VERSION_base(4,7,0)
import           Data.Typeable                   (Typeable)
#else
import           Data.Typeable                   (TyCon, Typeable, Typeable1 (..), mkTyCon3, mkTyConApp)
#endif
import           Network                         (Socket)
import           Numeric                         (readOct, showOct)
#if !MIN_VERSION_base(4,6,0)
import           Prelude                         hiding (catch)
#endif
import           System.Console.GetOpt           (ArgDescr (..), ArgOrder (Permute), OptDescr (..), getOpt, usageInfo)
import           System.Environment              hiding (getEnv)
#ifndef PORTABLE
import           Data.Char                       (isAlpha)
import           System.Posix.Env                (getEnv)
#endif
import           System.Exit                     (exitFailure)
import           System.IO                       (hPutStrLn, stderr)
------------------------------------------------------------------------------
import           Data.ByteString.Builder         (Builder, byteString, stringUtf8, toLazyByteString)
import qualified System.IO.Streams               as Streams
------------------------------------------------------------------------------
import           Snap.Core                       (MonadSnap, Request (rqClientAddr, rqClientPort), emptyResponse, finishWith, getRequest, logError, setContentLength, setContentType, setResponseBody, setResponseStatus)
import           Snap.Internal.Debug             (debug)
import           Snap.Internal.Http.Server.Types (AccessLogFunc)


------------------------------------------------------------------------------
-- | FIXME
--
-- Note: this type changed in snap-server 1.0.0.0.
data ProxyType = NoProxy
               | HaProxy
               | X_Forwarded_For
  deriving (Show, Eq, Typeable)

------------------------------------------------------------------------------
-- | Data type representing the configuration of an error logging target
data CmdlineConfigErrLog = ConfigNoErrLog                     -- ^ no logging
                         | ConfigFileErrLog FilePath          -- ^ log to text file
                         | ConfigIoErrLog (Builder -> IO ())  -- ^ log custom IO handler

instance Show CmdlineConfigErrLog where
    show ConfigNoErrLog       = "no log"
    show (ConfigFileErrLog f) = "log to file " ++ show f
    show (ConfigIoErrLog _)   = "custom logging handler"


------------------------------------------------------------------------------
-- | Data type representing the configuration of an error logging target
data CmdlineConfigAccessLog =
     ConfigNoAccessLog                -- ^ no logging
   | ConfigFileAccessLog FilePath     -- ^ log to text file
   | ConfigIoAccessLog AccessLogFunc  -- ^ log custom IO handler

instance Show CmdlineConfigAccessLog where
    show ConfigNoAccessLog       = "no log"
    show (ConfigFileAccessLog f) = "log to file " ++ show f
    show (ConfigIoAccessLog _)   = "custom logging handler"


------------------------------------------------------------------------------
-- We should be using ServerConfig here. There needs to be a clearer
-- separation between:
--
--   * what the underlying code needs to configure itself
--
--   * what the command-line processing does.
--
-- The latter will provide "library" helper functions that operate on
-- ServerConfig/etc in order to allow users to configure their own environment.
--
--
-- Todo:
--
--  * need a function ::
--      CommandLineConfig -> IO ([ServerConfig hookState, AcceptFunc])
--
--       this will prep for another function that will spawn all of the
--       accept loops with httpAcceptLoop.
--
--  * all backends provide "Some -> Foo -> Config -> IO AcceptFunc"
--
--  * add support for socket activation to command line, or delegate to
--    different library? It's linux-only anyways, need to ifdef. It would be
--    silly to depend on the socket-activation library for that one little
--    function.
--
--  * break config into multiple modules:
--
--     * everything that modifies the snap handler (compression, proxy
--       settings, error handler)
--
--     * everything that directly modifies server settings (hostname /
--       defaultTimeout / hooks / etc)
--
--     * everything that configures backends (port/bind/ssl*)
--
--     * everything that handles command line stuff
--
--     * utility stuff
--
-- Cruft that definitely must be removed:
--
--  * CmdlineConfigLog -- this becomes a binary option on the command-line side (no
--    logging or yes, to this file), but the ConfigIoLog gets zapped
--    altogether.

------------------------------------------------------------------------------
-- | A record type which represents partial configurations (for 'httpServe')
-- by wrapping all of its fields in a 'Maybe'. Values of this type are usually
-- constructed via its 'Monoid' instance by doing something like:
--
-- > setPort 1234 mempty
--
-- Any fields which are unspecified in the 'Config' passed to 'httpServe' (and
-- this is the norm) are filled in with default values from 'defaultConfig'.
data CmdlineConfig m a = CmdlineConfig
    { hostname       :: Maybe ByteString
    , accessLog      :: Maybe CmdlineConfigAccessLog
    , errorLog       :: Maybe CmdlineConfigErrLog
    , locale         :: Maybe String
    , port           :: Maybe Int
    , bind           :: Maybe ByteString
    , sslport        :: Maybe Int
    , sslbind        :: Maybe ByteString
    , sslcert        :: Maybe FilePath
    , sslchaincert   :: Maybe Bool
    , sslkey         :: Maybe FilePath
    , unixsocket     :: Maybe FilePath
    , unixaccessmode :: Maybe Int
    , compression    :: Maybe Bool
    , verbose        :: Maybe Bool
    , err404Handler  :: Maybe (m ())
    , errorHandler   :: Maybe (SomeException -> m ())
    , defaultTimeout :: Maybe Int
    , other          :: Maybe a
    , proxyType      :: Maybe ProxyType
    , startupHook    :: Maybe (StartupInfo m a -> IO ())
    }
#if MIN_VERSION_base(4,7,0)
  deriving Typeable
#else

------------------------------------------------------------------------------
-- | The 'Typeable1' instance is here so 'Config' values can be
-- dynamically loaded with Hint.
configTyCon :: TyCon
configTyCon = mkTyCon3 "snap-server" "Snap.Http.Server.CmdlineConfig"
                       "CmdlineConfig"
{-# NOINLINE configTyCon #-}

instance (Typeable1 m) => Typeable1 (CmdlineConfig m) where
    typeOf1 _ = mkTyConApp configTyCon [typeOf1 (undefined :: m ())]
#endif


instance Show (CmdlineConfig m a) where
    show c = unlines [ "CmdlineConfig:"
                     , "hostname: "       ++ _hostname
                     , "accessLog: "      ++ _accessLog
                     , "errorLog: "       ++ _errorLog
                     , "locale: "         ++ _locale
                     , "port: "           ++ _port
                     , "bind: "           ++ _bind
                     , "sslport: "        ++ _sslport
                     , "sslbind: "        ++ _sslbind
                     , "sslcert: "        ++ _sslcert
                     , "sslchaincert: "   ++ _sslchaincert
                     , "sslkey: "         ++ _sslkey
                     , "unixsocket: "     ++ _unixsocket
                     , "unixaccessmode: " ++ _unixaccessmode
                     , "compression: "    ++ _compression
                     , "verbose: "        ++ _verbose
                     , "defaultTimeout: " ++ _defaultTimeout
                     , "proxyType: "      ++ _proxyType
                     ]

      where
        _hostname       = show $ hostname       c
        _accessLog      = show $ accessLog      c
        _errorLog       = show $ errorLog       c
        _locale         = show $ locale         c
        _port           = show $ port           c
        _bind           = show $ bind           c
        _sslport        = show $ sslport        c
        _sslbind        = show $ sslbind        c
        _sslcert        = show $ sslcert        c
        _sslchaincert   = show $ sslchaincert   c
        _sslkey         = show $ sslkey         c
        _compression    = show $ compression    c
        _verbose        = show $ verbose        c
        _defaultTimeout = show $ defaultTimeout c
        _proxyType      = show $ proxyType      c
        _unixsocket     = show $ unixsocket     c
        _unixaccessmode = case unixaccessmode c of
                               Nothing -> "Nothing"
                               Just s -> ("Just 0" ++) . showOct s $ []


------------------------------------------------------------------------------
-- | Returns a completely empty 'Config'. Equivalent to 'mempty' from
-- 'Config''s 'Monoid' instance.
emptyCmdlineConfig :: CmdlineConfig m a
emptyCmdlineConfig = mempty


------------------------------------------------------------------------------
instance Monoid (CmdlineConfig m a) where
    mempty = CmdlineConfig
        { hostname       = Nothing
        , accessLog      = Nothing
        , errorLog       = Nothing
        , locale         = Nothing
        , port           = Nothing
        , bind           = Nothing
        , sslport        = Nothing
        , sslbind        = Nothing
        , sslcert        = Nothing
        , sslchaincert   = Nothing
        , sslkey         = Nothing
        , unixsocket     = Nothing
        , unixaccessmode = Nothing
        , compression    = Nothing
        , verbose        = Nothing
        , err404Handler  = Nothing
        , errorHandler   = Nothing
        , defaultTimeout = Nothing
        , other          = Nothing
        , proxyType      = Nothing
        , startupHook    = Nothing
        }

    a `mappend` b = CmdlineConfig
        { hostname       = ov hostname
        , accessLog      = ov accessLog
        , errorLog       = ov errorLog
        , locale         = ov locale
        , port           = ov port
        , bind           = ov bind
        , sslport        = ov sslport
        , sslbind        = ov sslbind
        , sslcert        = ov sslcert
        , sslchaincert   = ov sslchaincert
        , sslkey         = ov sslkey
        , unixsocket     = ov unixsocket
        , unixaccessmode = ov unixaccessmode
        , compression    = ov compression
        , verbose        = ov verbose
        , err404Handler  = ov err404Handler
        , errorHandler   = ov errorHandler
        , defaultTimeout = ov defaultTimeout
        , other          = ov other
        , proxyType      = ov proxyType
        , startupHook    = ov startupHook
        }
      where
        ov :: (CmdlineConfig m a -> Maybe b) -> Maybe b
        ov f = getLast $! (mappend `on` (Last . f)) a b


------------------------------------------------------------------------------
-- | These are the default values for the options
defaultCmdlineConfig :: MonadSnap m => CmdlineConfig m a
defaultCmdlineConfig = mempty
    { hostname       = Just "localhost"
    , accessLog      = Just $ ConfigFileAccessLog "log/access.log"
    , errorLog       = Just $ ConfigFileErrLog "log/error.log"
    , locale         = Just "en_US"
    , compression    = Just True
    , verbose        = Just True
    , err404Handler  = Just default404Handler
    , errorHandler   = Just defaultErrorHandler
    , bind           = Just "0.0.0.0"
    , sslbind        = Nothing
    , sslcert        = Nothing
    , sslkey         = Nothing
    , sslchaincert   = Nothing
    , defaultTimeout = Just 60
    }


------------------------------------------------------------------------------
-- | The hostname of the HTTP server. This field has the same format as an HTTP
-- @Host@ header; if a @Host@ header came in with the request, we use that,
-- otherwise we default to this value specified in the configuration.
getHostname       :: CmdlineConfig m a -> Maybe ByteString
getHostname = hostname

-- | Path to the access log
getAccessLog      :: CmdlineConfig m a -> Maybe CmdlineConfigAccessLog
getAccessLog = accessLog

-- | Path to the error log
getErrorLog       :: CmdlineConfig m a -> Maybe CmdlineConfigErrLog
getErrorLog = errorLog

-- | Gets the locale to use. Locales are used on Unix only, to set the
-- @LANG@\/@LC_ALL@\/etc. environment variable. For instance if you set the
-- locale to \"@en_US@\", we'll set the relevant environment variables to
-- \"@en_US.UTF-8@\".
getLocale         :: CmdlineConfig m a -> Maybe String
getLocale = locale

-- | Returns the port to listen on (for http)
getPort           :: CmdlineConfig m a -> Maybe Int
getPort = port

-- | Returns the address to bind to (for http)
getBind           :: CmdlineConfig m a -> Maybe ByteString
getBind = bind

-- | Returns the port to listen on (for https)
getSSLPort        :: CmdlineConfig m a -> Maybe Int
getSSLPort = sslport

-- | Returns the address to bind to (for https)
getSSLBind        :: CmdlineConfig m a -> Maybe ByteString
getSSLBind = sslbind

-- | Path to the SSL certificate file
getSSLCert        :: CmdlineConfig m a -> Maybe FilePath
getSSLCert = sslcert

-- | Indicates that the certificate file contains a certificate chain.
getSSLChainCert   :: CmdlineConfig m a -> Maybe Bool
getSSLChainCert = sslchaincert

-- | Path to the SSL key file
getSSLKey         :: CmdlineConfig m a -> Maybe FilePath
getSSLKey = sslkey

-- | File path to unix socket. Must be absolute path, but allows for symbolic
-- links.
getUnixSocket     :: CmdlineConfig m a -> Maybe FilePath
getUnixSocket = unixsocket

-- | Access mode for unix socket, by default is system specific.
-- This should only be used to grant additional permissions to created
-- socket file, and not to remove permissions set by default.
-- The only portable way to limit access to socket is creating it in a
-- directory with proper permissions set.
--
-- Most BSD systems ignore access permissions on unix sockets.
--
-- Note: This uses umask. There is a race condition if process creates other
-- files at the same time as opening a unix socket with this option set.
getUnixSocketAccessMode :: CmdlineConfig m a -> Maybe Int
getUnixSocketAccessMode = unixaccessmode

-- | If set and set to True, compression is turned on when applicable
getCompression    :: CmdlineConfig m a -> Maybe Bool
getCompression = compression

-- | Whether to write server status updates to stderr
getVerbose        :: CmdlineConfig m a -> Maybe Bool
getVerbose = verbose

-- | A MonadSnap action to handle 404 errors
getErrorHandler   :: CmdlineConfig m a -> Maybe (m ())
getErrorHandler = err404Handler

-- | A MonadSnap action to handle 500 errors
getErrorHandler   :: CmdlineConfig m a -> Maybe (SomeException -> m ())
getErrorHandler = errorHandler

getDefaultTimeout :: CmdlineConfig m a -> Maybe Int
getDefaultTimeout = defaultTimeout

getOther :: CmdlineConfig m a -> Maybe a
getOther = other

getProxyType :: CmdlineConfig m a -> Maybe ProxyType
getProxyType = proxyType

-- TODO(greg): remove
--
-- | A startup hook is run after the server initializes but before user request
-- processing begins. The server passes, through a 'StartupInfo' object, the
-- startup hook a list of the sockets it is listening on and the final
-- 'CmdlineConfig' object completed after command-line processing.
getStartupHook :: CmdlineConfig m a -> Maybe (StartupInfo m a -> IO ())
getStartupHook = startupHook


------------------------------------------------------------------------------
setHostname       :: ByteString              -> CmdlineConfig m a -> CmdlineConfig m a
setHostname x c = c { hostname = Just x }

setAccessLog      :: CmdlineConfigAccessLog  -> CmdlineConfig m a -> CmdlineConfig m a
setAccessLog x c = c { accessLog = Just x }

setErrorLog       :: CmdlineConfigErrLog     -> CmdlineConfig m a -> CmdlineConfig m a
setErrorLog x c = c { errorLog = Just x }

setLocale         :: String                  -> CmdlineConfig m a -> CmdlineConfig m a
setLocale x c = c { locale = Just x }

setPort           :: Int                     -> CmdlineConfig m a -> CmdlineConfig m a
setPort x c = c { port = Just x }

setBind           :: ByteString              -> CmdlineConfig m a -> CmdlineConfig m a
setBind x c = c { bind = Just x }

setSSLPort        :: Int                     -> CmdlineConfig m a -> CmdlineConfig m a
setSSLPort x c = c { sslport = Just x }

setSSLBind        :: ByteString              -> CmdlineConfig m a -> CmdlineConfig m a
setSSLBind x c = c { sslbind = Just x }

setSSLCert        :: FilePath                -> CmdlineConfig m a -> CmdlineConfig m a
setSSLCert x c = c { sslcert = Just x }

setSSLChainCert   :: Bool                    -> CmdlineConfig m a -> CmdlineConfig m a
setSSLChainCert x c = c { sslchaincert = Just x }

setSSLKey         :: FilePath                -> CmdlineConfig m a -> CmdlineConfig m a
setSSLKey x c = c { sslkey = Just x }

setUnixSocket     :: FilePath                -> CmdlineConfig m a -> CmdlineConfig m a
setUnixSocket x c = c { unixsocket = Just x }

setUnixSocketAccessMode :: Int               -> CmdlineConfig m a -> CmdlineConfig m a
setUnixSocketAccessMode p c = c { unixaccessmode = Just ( p .&. 0o777) }

setCompression    :: Bool                    -> CmdlineConfig m a -> CmdlineConfig m a
setCompression x c = c { compression = Just x }

setVerbose        :: Bool                    -> CmdlineConfig m a -> CmdlineConfig m a
setVerbose x c = c { verbose = Just x }

setErr404Handler   :: (SomeException -> m ()) -> CmdlineConfig m a -> CmdlineConfig m a
setErr404Handler x c = c { err404Handler = Just x }

setErrorHandler   :: (SomeException -> m ()) -> CmdlineConfig m a -> CmdlineConfig m a
setErrorHandler x c = c { errorHandler = Just x }

setDefaultTimeout :: Int                     -> CmdlineConfig m a -> CmdlineConfig m a
setDefaultTimeout x c = c { defaultTimeout = Just x }

setOther          :: a                       -> CmdlineConfig m a -> CmdlineConfig m a
setOther x c = c { other = Just x }

setProxyType      :: ProxyType               -> CmdlineConfig m a -> CmdlineConfig m a
setProxyType x c = c { proxyType = Just x }

-- TODO(greg): remove
--
setStartupHook    :: (StartupInfo m a -> IO ()) -> CmdlineConfig m a -> CmdlineConfig m a
setStartupHook x c = c { startupHook = Just x }


------------------------------------------------------------------------------

-- TODO(greg): remove
--
-- | Arguments passed to 'setStartupHook'.
data StartupInfo m a = StartupInfo
    { startupHookConfig  :: CmdlineConfig m a
    , startupHookSockets :: [Socket]
    }

-- TODO(greg): remove
--
emptyStartupInfo :: StartupInfo m a
emptyStartupInfo = StartupInfo emptyCmdlineConfig []

-- TODO(greg): remove
--
-- | The 'Socket's opened by the server. There will be two 'Socket's for SSL
-- connections, and one otherwise.
getStartupSockets :: StartupInfo m a -> [Socket]
getStartupSockets = startupHookSockets

-- TODO(greg): remove
--
-- The 'CmdlineConfig', after any command line parsing has been performed.
getStartupConfig :: StartupInfo m a -> CmdlineConfig m a
getStartupConfig = startupHookConfig

-- TODO(greg): remove
--
setStartupSockets :: [Socket] -> StartupInfo m a -> StartupInfo m a
setStartupSockets x c = c { startupHookSockets = x }

-- TODO(greg): remove
--
setStartupConfig :: CmdlineConfig m a -> StartupInfo m a -> StartupInfo m a
setStartupConfig x c = c { startupHookConfig = x }


------------------------------------------------------------------------------
bsFromString :: String -> ByteString
bsFromString = T.encodeUtf8 . T.pack


------------------------------------------------------------------------------
toString :: ByteString -> String
toString = T.unpack . T.decodeUtf8


------------------------------------------------------------------------------
-- | Returns a description of the snap command line options suitable for use
-- with "System.Console.GetOpt".
optDescrs :: forall m a . MonadSnap m =>
             CmdlineConfig m a         -- ^ the configuration defaults.
          -> [OptDescr (Maybe (CmdlineConfig m a))]
optDescrs defaults =
    [ Option "" ["hostname"]
             (ReqArg (Just . setConfig setHostname . bsFromString) "NAME")
             $ "local hostname" ++ defaultC getHostname
    , Option "b" ["address"]
             (ReqArg (\s -> Just $ mempty { bind = Just $ bsFromString s })
                     "ADDRESS")
             $ "address to bind to" ++ defaultO bind
    , Option "p" ["port"]
             (ReqArg (\s -> Just $ mempty { port = Just $ read s}) "PORT")
             $ "port to listen on" ++ defaultO port
    , Option "" ["ssl-address"]
             (ReqArg (\s -> Just $ mempty { sslbind = Just $ bsFromString s })
                     "ADDRESS")
             $ "ssl address to bind to" ++ defaultO sslbind
    , Option "" ["ssl-port"]
             (ReqArg (\s -> Just $ mempty { sslport = Just $ read s}) "PORT")
             $ "ssl port to listen on" ++ defaultO sslport
    , Option "" ["ssl-cert"]
             (ReqArg (\s -> Just $ mempty { sslcert = Just s}) "PATH")
             $ "path to ssl certificate in PEM format" ++ defaultO sslcert
   , Option [] ["ssl-chain-cert"]
             (NoArg $ Just $ setConfig setSSLChainCert True)
             $ "certificate file contains complete certificate chain" ++ defaultB sslchaincert "site certificate only" "complete certificate chain"
    , Option [] ["no-ssl-chain-cert"]
             (NoArg $ Just $ setConfig setSSLChainCert False)
             $ "certificate file contains only the site certificate" ++ defaultB sslchaincert "site certificate only" "complete certificate chain"
    , Option [] ["ssl-key"]
             (ReqArg (\s -> Just $ mempty { sslkey = Just s}) "PATH")
             $ "path to ssl private key in PEM format" ++ defaultO sslkey
    , Option "" ["access-log"]
             (ReqArg (Just . setConfig setAccessLog . ConfigFileAccessLog) "PATH")
             $ "access log" ++ defaultC getAccessLog
    , Option "" ["error-log"]
             (ReqArg (Just . setConfig setErrorLog . ConfigFileErrLog) "PATH")
             $ "error log" ++ defaultC getErrorLog
    , Option "" ["no-access-log"]
             (NoArg $ Just $ setConfig setAccessLog ConfigNoAccessLog)
             "don't have an access log"
    , Option "" ["no-error-log"]
             (NoArg $ Just $ setConfig setErrorLog ConfigNoErrLog)
             "don't have an error log"
    , Option "c" ["compression"]
             (NoArg $ Just $ setConfig setCompression True)
             $ "use gzip compression on responses" ++
               defaultB getCompression "compressed" "uncompressed"
    , Option "t" ["timeout"]
             (ReqArg (\t -> Just $ mempty {
                              defaultTimeout = Just $ read t
                            }) "SECS")
             $ "set default timeout in seconds" ++ defaultC defaultTimeout
    , Option "" ["no-compression"]
             (NoArg $ Just $ setConfig setCompression False)
             $ "serve responses uncompressed" ++
               defaultB compression "compressed" "uncompressed"
    , Option "v" ["verbose"]
             (NoArg $ Just $ setConfig setVerbose True)
             $ "print server status updates to stderr" ++
               defaultC getVerbose
    , Option "q" ["quiet"]
             (NoArg $ Just $ setConfig setVerbose False)
             $ "do not print anything to stderr" ++
               defaultB getVerbose "verbose" "quiet"
    , Option "" ["proxy"]
             (ReqArg (Just . setConfig setProxyType . parseProxy . CI.mk)
                     "X_Forwarded_For")
             $ concat [ "Set --proxy=X_Forwarded_For if your snap application \n"
                      , "is behind an HTTP reverse proxy to ensure that \n"
                      , "rqClientAddr is set properly.\n"
                      , "Set --proxy=haproxy to use the haproxy protocol\n("
                      , "http://haproxy.1wt.eu/download/1.5/doc/proxy-protocol.txt)"
                      , defaultC getProxyType ]
    , Option "" ["unix-socket"]
             (ReqArg (Just . setConfig setUnixSocket) "PATH")
             $ concat ["Absolute path to unix socket file. "
                      , "File will be removed if already exists"]
    , Option "" ["unix-socket-mode"]
             (ReqArg (Just . setConfig setUnixSocketAccessMode . parseOctal)
                     "MODE")
             $ concat ["Access mode for unix socket in octal, for example 0760.\n"
                      ," Default is system specific."]
    , Option "h" ["help"]
             (NoArg Nothing)
             "display this help and exit"
    ]

  where
    parseProxy s | s == "NoProxy"         = NoProxy
                 | s == "X_Forwarded_For" = X_Forwarded_For
                 | s == "haproxy"         = HaProxy
                 | otherwise = error $ concat [
                         "Error (--proxy): expected one of 'NoProxy', "
                       , "'X_Forwarded_For', or 'haproxy'. Got '"
                       , CI.original s
                       , "'"
                       ]
    parseOctal s = case readOct s of
          ((v, _):_) | v >= 0 && v <= 0o777 -> v
          _ -> error $ "Error (--unix-socket-mode): expected octal access mode"

    setConfig f c  = f c mempty
    conf           = defaultCmdlineConfig `mappend` defaults

    defaultB :: (CmdlineConfig m a -> Maybe Bool) -> String -> String -> String
    defaultB f y n = (maybe "" (\b -> ", default " ++ if b
                                                        then y
                                                        else n) $ f conf) :: String

    defaultC :: (Show b) => (CmdlineConfig m a -> Maybe b) -> String
    defaultC f     = maybe "" ((", default " ++) . show) $ f conf

    defaultO :: (Show b) => (CmdlineConfig m a -> Maybe b) -> String
    defaultO f     = maybe ", default off" ((", default " ++) . show) $ f conf


------------------------------------------------------------------------------
default404Handler :: MonadSnap m => m ()
default404Handler =
  clearContentLength                $
  setResponseStatus 404 "Not Found" $
  setResponseBody enum404           $
  emptyResponse

  where

    --------------------------------------------------------------------------
    enum404 out = do
        is <- Streams.fromList html
        Streams.connect is out
        return out

    --------------------------------------------------------------------------
    html = map byteString [ "<!DOCTYPE html>\n"
                          , "<html>\n"
                          , "<head>\n"
                          , "<title>Not found</title>\n"
                          , "</head>\n"
                          , "<body>\n"
                          , "<code>No handler accepted \""
                          , rqURI req
                          , "\"</code>\n</body></html>"
                          ]



------------------------------------------------------------------------------
defaultErrorHandler :: MonadSnap m => SomeException -> m ()
defaultErrorHandler e = do
    debug "Snap.Http.Server.CmdlineConfig errorHandler:"
    req <- getRequest
    let sm = smsg req
    debug $ toString sm
    logError sm

    finishWith $ setContentType "text/plain; charset=utf-8"
               . setContentLength (fromIntegral $ S.length msg)
               . setResponseStatus 500 "Internal Server Error"
               . setResponseBody errBody
               $ emptyResponse

  where
    errBody os = Streams.write (Just msgB) os >> return os

    toByteString = S.concat . L.toChunks . toLazyByteString
    smsg req = toByteString $ requestErrorMessage req e

    msg  = toByteString msgB
    msgB = mconcat [
             byteString "A web handler threw an exception. Details:\n"
           , stringUtf8 $ show e
           ]


------------------------------------------------------------------------------
-- | Returns a 'Config' obtained from parsing command-line options, using the
-- default Snap 'OptDescr' set.
--
-- On Unix systems, the locale is read from the @LANG@ environment variable.
cmdlineConfig :: MonadSnap m
              => CmdlineConfig m a
                  -- ^ default configuration. This is combined with
                  -- 'defaultCmdlineConfig' to obtain default values to use if the
                  -- given parameter is specified on the command line.
                  -- Usually it is fine to use 'emptyCmdlineConfig' here.
              -> IO (CmdlineConfig m a)
cmdlineConfig defaults = extendedCmdlineConfig (optDescrs defaults) f defaults
  where
    -- Here getOpt can ever change the "other" field, because we only use the
    -- Snap OptDescr list. The combining function will never be invoked.
    f = undefined


------------------------------------------------------------------------------
-- | Returns a 'CmdlineConfig' obtained from parsing command-line options,
-- using the default Snap 'OptDescr' set as well as a list of user OptDescrs.
-- User OptDescrs use the \"other\" field (accessible using 'getOther' and
-- 'setOther') to store additional command-line option state. These are
-- combined using a user-defined combining function.
--
-- On Unix systems, the locale is read from the @LANG@ environment variable.

extendedCmdlineConfig :: MonadSnap m
                      => [OptDescr (Maybe (CmdlineConfig m a))]
                         -- ^ User options.
                      -> (a -> a -> a)
                         -- ^ State for multiple invoked user command-line
                         -- options will be combined using this function.
                      -> CmdlineConfig m a
                         -- ^ default configuration. This is combined with
                         -- Snap's 'defaultCmdlineConfig' to obtain default
                         -- values to use if the given parameter is
                         -- specified on the command line. Usually it is
                         -- fine to use 'emptyCmdlineConfig' here.
                      -> IO (CmdlineConfig m a)
extendedCmdlineConfig opts combiningFunction defaults = do
    args <- getArgs
    prog <- getProgName

    result <- either (usage prog)
                     return
                     (case getOpt Permute opts args of
                        (f, _, []  ) -> maybe (Left []) Right $
                                        fmap (foldl' combine mempty) $
                                        sequence f
                        (_, _, errs) -> Left errs)

#ifndef PORTABLE
    lang <- getEnv "LANG"
    return $! mconcat [ defaults
                      , mempty {locale = fmap upToUtf8 lang}
                      , result ]
#else
    return $! mconcat [defaults, result]
#endif

  where
    usage prog errs = do
        let hdr = "Usage:\n  " ++ prog ++ " [OPTION...]\n\nOptions:"
        let msg = concat errs ++ usageInfo hdr opts
        hPutStrLn stderr msg
        exitFailure
#ifndef PORTABLE
    upToUtf8 = takeWhile $ \c -> isAlpha c || '_' == c
#endif

    combine !a !b = a `mappend` b `mappend` newOther
      where
        -- combined is only a Just if both a and b have other fields, and then
        -- we use the combining function. CmdlineConfig's mappend picks the
        -- last "Just" in the other list.
        combined = do
            x <- getOther a
            y <- getOther b
            return $! combiningFunction x y

        newOther = mempty { other = combined }

fmapArg :: (a -> b) -> ArgDescr a -> ArgDescr b
fmapArg f (NoArg a) = NoArg (f a)
fmapArg f (ReqArg g s) = ReqArg (f . g) s
fmapArg f (OptArg g s) = OptArg (f . g) s

fmapOpt :: (a -> b) -> OptDescr a -> OptDescr b
fmapOpt f (Option s l d e) = Option s l (fmapArg f d) e


------------------------------------------------------------------------------
requestErrorMessage :: Request -> SomeException -> Builder
requestErrorMessage req e =
    mconcat [ byteString "During processing of request from "
            , byteString $ rqClientAddr req
            , byteString ":"
            , fromShow $ rqClientPort req
            , byteString "\nrequest:\n"
            , fromShow $ show req
            , byteString "\n"
            , msgB
            ]
  where
    msgB = mconcat [
             byteString "A web handler threw an exception. Details:\n"
           , fromShow e
           ]

------------------------------------------------------------------------------
fromShow :: Show a => a -> Builder
fromShow = stringUtf8 . show
