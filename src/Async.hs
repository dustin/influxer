module Async (async, link, cancel, withAsync, mapConcurrently_, waitCatch) where

import           Cleff
import qualified Control.Concurrent.Async as A
import           Control.Exception        (SomeException)

async :: MonadUnliftIO m => m a -> m (A.Async a)
async m = withRunInIO $ \run -> A.async $ run m

link :: MonadUnliftIO m => A.Async a -> m ()
link = liftIO . A.link

cancel :: MonadUnliftIO m => A.Async a -> m ()
cancel = liftIO . A.cancel

waitCatch :: MonadUnliftIO m => A.Async a -> m (Either SomeException a)
waitCatch = liftIO . A.waitCatch

withAsync :: MonadUnliftIO m => m a -> (A.Async a -> m b) -> m b
withAsync m f = f =<< async m

mapConcurrently_ :: (MonadUnliftIO m, Foldable t) => (a -> m b) -> t a -> m ()
mapConcurrently_ f stuff = withRunInIO $ \run -> A.mapConcurrently_ (run . f) stuff
