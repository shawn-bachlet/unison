{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ViewPatterns        #-}

module Unison.CommandLine.Main 
  ( main
  ) where

import Unison.Prelude

import Control.Concurrent.STM (atomically)
import Control.Exception (finally, catch, AsyncException(UserInterrupt), asyncExceptionFromException)
import Control.Monad.State (runStateT)
import Data.Configurator.Types (Config)
import Data.IORef
import Prelude hiding (readFile, writeFile)
import System.IO.Error (isDoesNotExistError)
import Unison.Codebase.Branch (Branch)
import qualified Unison.Codebase.Branch as Branch
import Unison.Codebase.Editor.Input (Input (..), Event)
import qualified Unison.Server.CodebaseServer as Server
import qualified Unison.Codebase.Editor.HandleInput as HandleInput
import qualified Unison.Codebase.Editor.HandleCommand as HandleCommand
import Unison.Codebase.Editor.Command (LoadSourceResult(..))
import Unison.Codebase (Codebase)
import Unison.CommandLine
import Unison.PrettyTerminal
import Unison.CommandLine.InputPattern (ArgumentType (suggestions), InputPattern (aliases, patternName))
import Unison.CommandLine.InputPatterns (validInputs)
import Unison.CommandLine.OutputMessages (notifyUser, notifyNumbered)
import Unison.Parser.Ann (Ann)
import Unison.Symbol (Symbol)
import qualified Control.Concurrent.Async as Async
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO
import qualified System.Console.Haskeline as Line
import qualified Crypto.Random        as Random
import qualified Unison.Codebase.Path as Path
import qualified Unison.Codebase.Runtime as Runtime
import qualified Unison.Codebase as Codebase
import qualified Unison.CommandLine.InputPattern as IP
import qualified Unison.Util.Pretty as P
import qualified Unison.Util.TQueue as Q
import qualified Unison.CommandLine.Welcome as Welcome
import Control.Lens (view)
import Control.Error (rightMay)
import UnliftIO (catchSyncOrAsync, throwIO, withException)
import System.IO (hPutStrLn, stderr)
import Unison.Codebase.Editor.Output (Output)

getUserInput
  :: forall m v a
   . (MonadIO m, Line.MonadException m)
  => Map String InputPattern
  -> Codebase m v a
  -> Branch m
  -> Path.Absolute
  -> [String]
  -> m Input
getUserInput patterns codebase rootBranch currentPath numberedArgs = Line.runInputT
  settings
  (haskelineCtrlCHandling go)
 where
  -- Catch ctrl-c and simply re-render the prompt.
  haskelineCtrlCHandling :: Line.InputT m b -> Line.InputT m b
  haskelineCtrlCHandling act = do
    -- We return a Maybe result to ensure we don't nest an action within the masked exception
    -- handler.
    Line.handleInterrupt (pure Nothing) (Line.withInterrupt (Just <$> act)) >>= \case
      Nothing -> haskelineCtrlCHandling act
      Just a -> pure a
  go :: Line.InputT m Input
  go = do
    line <- Line.getInputLine
      $ P.toANSI 80 ((P.green . P.shown) currentPath <> fromString prompt)
    case line of
      Nothing -> pure QuitI
      Just l  -> case words l of
        [] -> go
        ws ->
          case parseInput (Branch.head rootBranch) currentPath numberedArgs patterns $ ws of
            Left msg -> do
              liftIO $ putPrettyLn msg
              go
            Right i -> pure i
  settings :: Line.Settings m
  settings    = Line.Settings tabComplete (Just ".unisonHistory") True
  tabComplete :: Line.CompletionFunc m
  tabComplete = Line.completeWordWithPrev Nothing " " $ \prev word ->
    -- User hasn't finished a command name, complete from command names
    if null prev
      then pure . exactComplete word $ Map.keys patterns
    -- User has finished a command name; use completions for that command
      else case words $ reverse prev of
        h : t -> fromMaybe (pure []) $ do
          p       <- Map.lookup h patterns
          argType <- IP.argType p (length t)
          pure $ suggestions argType word codebase rootBranch currentPath
        _ -> pure []

main
  :: FilePath
  -> Welcome.Welcome
  -> Path.Absolute
  -> (Config, IO ())
  -> [Either Event Input]
  -> Runtime.Runtime Symbol
  -> Codebase IO Symbol Ann
  -> Maybe Server.BaseUrl
  -> IO ()
main dir welcome initialPath (config, cancelConfig) initialInputs runtime codebase serverBaseUrl = do
  root <- fromMaybe Branch.empty . rightMay <$> Codebase.getRootBranch codebase
  eventQueue <- Q.newIO
  welcomeEvents <-Welcome.run codebase welcome
  do
    -- we watch for root branch tip changes, but want to ignore ones we expect.
    rootRef                  <- newIORef root
    pathRef                  <- newIORef initialPath
    initialInputsRef         <- newIORef $ welcomeEvents ++ initialInputs
    numberedArgsRef          <- newIORef []
    pageOutput               <- newIORef True
    cancelFileSystemWatch    <- watchFileSystem eventQueue dir
    cancelWatchBranchUpdates <- watchBranchUpdates (readIORef rootRef)
                                                   eventQueue
                                                   codebase
    let patternMap :: Map String InputPattern
        patternMap =
          Map.fromList
            $   validInputs
            >>= (\p -> (patternName p, p) : ((, p) <$> aliases p))
    let getInput :: IO Input
        getInput = do
          root <- readIORef rootRef
          path <- readIORef pathRef
          numberedArgs <- readIORef numberedArgsRef
          getUserInput patternMap codebase root path numberedArgs
    let loadSourceFile :: Text -> IO LoadSourceResult
        loadSourceFile fname =
          if allow $ Text.unpack fname
            then
              let handle :: IOException -> IO LoadSourceResult
                  handle e =
                    case e of
                      _ | isDoesNotExistError e -> return InvalidSourceNameError
                      _ -> return LoadError
                  go = do
                    contents <- Data.Text.IO.readFile $ Text.unpack fname
                    return $ LoadSuccess contents
                  in catch go handle
            else return InvalidSourceNameError
    let notify :: Output Symbol -> IO ()
        notify = notifyUser dir >=> (\o ->
          ifM (readIORef pageOutput)
              (putPrettyNonempty o)
              (putPrettyLnUnpaged o))

    let interruptHandler :: SomeException -> IO (Either Event Input)
        interruptHandler (asyncExceptionFromException -> Just UserInterrupt) = awaitInput
        interruptHandler e = hPutStrLn stderr ("Exception: " <> show e) *> throwIO e
        cleanup = do
          Runtime.terminate runtime
          cancelConfig
          cancelFileSystemWatch
          cancelWatchBranchUpdates
        awaitInput :: IO (Either Event Input)
        awaitInput = do
          -- use up buffered input before consulting external events
          i <- readIORef initialInputsRef
          (case i of
            h:t -> writeIORef initialInputsRef t >> pure h
            [] ->
              -- Race the user input and file watch.
              Async.race (atomically $ Q.peek eventQueue) getInput >>= \case
                Left _ -> do
                  let e = Left <$> atomically (Q.dequeue eventQueue)
                  writeIORef pageOutput False
                  e
                x      -> do
                  writeIORef pageOutput True
                  pure x) `catchSyncOrAsync` interruptHandler

    let loop :: HandleInput.LoopState IO Symbol -> IO ()
        loop state = do
          writeIORef pathRef (view HandleInput.currentPath state)
          let free = runStateT (runMaybeT HandleInput.loop) state
          (o, state') <- HandleCommand.commandLine config awaitInput
                                       (writeIORef rootRef)
                                       runtime
                                       notify
                                       (\o -> let (p, args) = notifyNumbered o in
                                        putPrettyNonempty p $> args)
                                       loadSourceFile
                                       codebase
                                       serverBaseUrl
                                       (const Random.getSystemDRG)
                                       free
          case o of
            Nothing -> pure ()
            Just () -> do
              writeIORef numberedArgsRef (HandleInput._numberedArgs state')
              loop state'
    -- Run the main program loop, always run cleanup, 
    -- If an exception occurred, print it before exiting.
    (loop (HandleInput.loopState0 root initialPath)
      `withException` \e -> hPutStrLn stderr ("Exception: " <> show (e :: SomeException)))
      `finally` cleanup
