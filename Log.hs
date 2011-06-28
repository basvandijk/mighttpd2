{-# LANGUAGE OverloadedStrings, DoAndIfThenElse #-}

module Log where

import Buffer
import Control.Applicative
import Control.Concurrent
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BS
import Data.IORef
import Data.Time
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Application.Classic
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Locale
import System.Posix.Files
import System.Posix.IO hiding (fdWrite,fdWriteBuf)
import System.Posix.IO.ByteString
import System.Posix.Process
import System.Posix.Signals
import System.Posix.Types
import Queue

data FileLogSpec = FileLogSpec {
    log_file :: String
  , log_file_size :: Integer
  , log_backup_number :: Int
  , log_buffer_size :: Int
  , log_flush_period :: Int
  }

type TimeRef = IORef ByteString

----------------------------------------------------------------

fileCheck :: FileLogSpec -> IO ()
fileCheck spec = do
    dirperm <- getPermissions dir
    unless (writable dirperm) $ exit $ dir ++ " is not writable"
    fileexist <- doesFileExist file
    when fileexist $ do
        fileperm <- getPermissions file
        unless (writable fileperm) $ exit $ file ++ " is not writable"
  where
    file = log_file spec
    dir = takeDirectory file
    exit msg = hPutStrLn stderr msg >> exitFailure

fileInit :: FileLogSpec -> IO (TimeRef,QueueRef)
fileInit spec = do
    fd <- open spec
    buf <- createBuffer (log_buffer_size spec)
    mvar <- newMVar (fd,buf)
    qref <- emptyQ
    ref <- timeKeeperInit
    forkIO $ fileFlusher spec mvar
    forkIO $ fileSerializer qref mvar
    let flushHandler = fileFlushHandler mvar
        rotateHandler = fileRotateHandler spec mvar
    installHandler sigTERM flushHandler Nothing
    installHandler sigINT flushHandler Nothing
    installHandler sigHUP rotateHandler Nothing
    return (ref,qref)

----------------------------------------------------------------

fileSerializer :: QueueRef -> MVar (Fd,Buffer) -> IO ()
fileSerializer qref mvar = forever $ do
    mbss <- dequeue qref
    case mbss of
        Nothing  -> threadDelay 10000
        Just bss -> do
            (fd,buf) <- takeMVar mvar
            mbuf <- copyByteStrings buf bss
            case mbuf of
                Nothing -> do
                    buf' <- writeBuffer fd buf
                    Just buf'' <- copyByteStrings buf' bss -- xxx
                    putMVar mvar (fd,buf'')
                Just buf' -> putMVar mvar (fd,buf')

----------------------------------------------------------------

fileFlush :: MVar (Fd, Buffer) -> IO ()
fileFlush mvar = do
    (fd,buf) <- takeMVar mvar
    buf' <- writeBuffer fd buf
    putMVar mvar (fd,buf')

fileFlushHandler :: MVar (Fd,Buffer) -> Handler
fileFlushHandler mvar = Catch $ do
    fileFlush mvar
    exitImmediately ExitSuccess

fileFlusher :: FileLogSpec -> MVar (Fd,Buffer) -> IO ()
fileFlusher spec mvar = forever $ do
    threadDelay $ log_flush_period spec
    fileFlusher spec mvar

----------------------------------------------------------------

open :: FileLogSpec -> IO Fd
open spec = openFd file WriteOnly (Just 0o644) defaultFileFlags { append = True }
  where
    file = log_file spec

rotate :: FileLogSpec -> IO ()
rotate spec = mapM_ move srcdsts
  where
    path = log_file spec
    n = log_backup_number spec
    dsts' = reverse . ("":) . map (('.':). show) $ [0..n-1]
    dsts = map (path++) dsts'
    srcs = tail dsts
    srcdsts = zip srcs dsts
    move (src,dst) = do
        exist <- doesFileExist src
        when exist $ renameFile src dst

fileRotateHandler :: FileLogSpec -> MVar (Fd, Buffer) -> Handler
fileRotateHandler spec mvar = Catch $ do
    (fd,buf) <- takeMVar mvar
    buf' <- writeBuffer fd buf
    closeFd fd
    fd' <- open spec
    putMVar mvar (fd',buf')

fileRotater :: FileLogSpec -> [ProcessID] -> IO ()
fileRotater spec ps = do
    threadDelay 10000000
    exist <- doesFileExist $ log_file spec
    when exist $ do
        size <- fromIntegral . fileSize <$> getFileStatus (log_file spec)
        when (size > log_file_size spec) $ do
            rotate spec
            mapM_ (signalProcess sigHUP) ps
    fileRotater spec ps

----------------------------------------------------------------

stdoutInit :: IO (TimeRef,QueueRef)
stdoutInit = do
    qref <- emptyQ
    ref <- timeKeeperInit
    forkIO $ timeKeeper ref
    forkIO $ stdoutSerializer qref
    return (ref,qref)

stdoutSerializer :: QueueRef -> IO ()
stdoutSerializer qref = forever $ do
    mbss <- dequeue qref
    case mbss of
        Nothing  -> threadDelay 10000
        Just bss -> do
            fdWrite 1 $ BS.concat bss
            return ()

----------------------------------------------------------------

mightyLogger :: (TimeRef,QueueRef) -> Request -> Status -> Maybe Integer -> IO ()
mightyLogger (ref,qref) req st msize = do
    addr <- getPeerAddr (remoteHost req)
    tmstr <- readIORef ref
    flip enqueue qref [
        BS.pack addr
      , " - - ["
      , tmstr
      , "] \""
      , requestMethod req
      , " "
      , rawPathInfo req
      , "\" "
      , BS.pack (show . statusCode $ st)
      , " "
      , BS.pack (maybe "-" show msize)
      , " \"" -- size
      , lookupRequestField' "referer" req
      , "\" \""
      , lookupRequestField' "user-agent" req
      , "\"\n"
      ]

----------------------------------------------------------------

timeKeeperInit :: IO (TimeRef)
timeKeeperInit = timeByteString >>= newIORef

timeKeeper :: TimeRef -> IO ()
timeKeeper ref = do
    tmstr <- timeByteString
    atomicModifyIORef ref (\_ -> (tmstr, undefined))
    threadDelay 1000000
    timeKeeper ref

timeByteString :: IO ByteString
timeByteString =
    BS.pack . formatTime defaultTimeLocale "%d/%b/%Y:%T %z" <$> getZonedTime
