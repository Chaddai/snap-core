{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}

module Snap.Util.FileUploads
  ( -- * Datatypes
    PartInfo(..)

    -- ** Policy
    -- *** General upload policy
  , UploadPolicy
  , defaultUploadPolicy
  , doProcessFormInputs
  , setProcessFormInputs
  , getMaximumFormInputSize
  , setMaximumFormInputSize
  , getMinimumUploadRate
  , setMinimumUploadRate
  , getMinimumUploadSeconds
  , setMinimumUploadSeconds
  , getUploadTimeout
  , setUploadTimeout

    -- *** Per-file upload policy
  , PartUploadPolicy
  , disallow
  , allowWithMaximumSize

    -- * Exceptions
  , FileUploadException
  , fileUploadExceptionReason
  , BadPartException
  , badPartExceptionReason
  , PolicyViolationException
  , policyViolationExceptionReason

    -- * Functions
  , handleFileUploads
  , handleMultipart
  ) where

------------------------------------------------------------------------------
import           Control.Arrow
import           Control.Applicative
import           Control.Exception (SomeException(..))
import           Control.Monad
import           Control.Monad.CatchIO
import           Control.Monad.Trans
import qualified Data.Attoparsec.Char8 as Atto
import           Data.Attoparsec.Char8 hiding (many, Result(..))
import           Data.Attoparsec.Enumerator
import           Data.CIByteString
import qualified Data.ByteString.Char8 as S
import           Data.ByteString.Char8 (ByteString)
import           Data.ByteString.Internal (c2w)
import qualified Data.DList as D
import           Data.Enumerator.Binary (iterHandle)
import           Data.IORef
import           Data.Int
import           Data.List hiding (takeWhile)
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Text as T
import           Data.Text (Text)
import qualified Data.Text.Encoding as TE
import           Data.Typeable
import           Prelude hiding (catch, getLine, takeWhile)
import           System.Directory
import           System.IO hiding (isEOF)
------------------------------------------------------------------------------
import           Snap.Iteratee hiding (map)
import qualified Snap.Iteratee as I
import           Snap.Internal.Debug
import           Snap.Internal.Iteratee.Debug
import           Snap.Internal.Iteratee.KnuthMorrisPratt
import           Snap.Internal.Parsing
import           Snap.Types


------------------------------------------------------------------------------
-- | 'PartInfo' contains information about a \"part\" in a request uploaded
-- with @Content-type: multipart/form-data@.
data PartInfo =
    PartInfo { partFieldName   :: !ByteString
             , partFileName    :: !(Maybe ByteString)
             , partContentType :: !ByteString
             }
  deriving (Show)


------------------------------------------------------------------------------
data FileUploadException =
    GenericFileUploadException {
      _genericFileUploadExceptionReason :: Text
    }
  | forall e . (Exception e, Show e) =>
    WrappedFileUploadException {
      _wrappedFileUploadException :: e
    , _wrappedFileUploadExceptionReason :: Text
    }
  deriving (Typeable)


------------------------------------------------------------------------------
instance Show FileUploadException where
    show (GenericFileUploadException r) = "File upload exception: " ++
                                          T.unpack r
    show (WrappedFileUploadException e _) = show e


------------------------------------------------------------------------------
instance Exception FileUploadException


------------------------------------------------------------------------------
fileUploadExceptionReason :: FileUploadException -> Text
fileUploadExceptionReason (GenericFileUploadException r) = r
fileUploadExceptionReason (WrappedFileUploadException _ r) = r


------------------------------------------------------------------------------
uploadExceptionToException :: Exception e => e -> Text -> SomeException
uploadExceptionToException e r = SomeException $ WrappedFileUploadException e r


------------------------------------------------------------------------------
uploadExceptionFromException :: Exception e => SomeException -> Maybe e
uploadExceptionFromException x = do
    WrappedFileUploadException e _ <- fromException x
    cast e


------------------------------------------------------------------------------
data BadPartException = BadPartException { badPartExceptionReason :: Text }
  deriving (Typeable)

instance Exception BadPartException where
    toException e@(BadPartException r) = uploadExceptionToException e r
    fromException = uploadExceptionFromException

instance Show BadPartException where
  show (BadPartException s) = "Bad part: " ++ T.unpack s


------------------------------------------------------------------------------
data PolicyViolationException = PolicyViolationException {
      policyViolationExceptionReason :: Text
    } deriving (Typeable)

instance Exception PolicyViolationException where
    toException e@(PolicyViolationException r) = uploadExceptionToException e r
    fromException = uploadExceptionFromException

instance Show PolicyViolationException where
  show (PolicyViolationException s) = "File upload policy violation: "
                                            ++ T.unpack s


------------------------------------------------------------------------------
-- | 'UploadPolicy' controls overall policy decisions relating to
-- @multipart/form-data@ uploads, specifically:
--
-- * whether to treat parts without filenames as form input (reading them into
--   the 'rqParams' map)
--
-- * because form input is read into memory, the maximum size of a form input
--   read in this manner
--
-- * the minimum upload rate a client must maintain before we kill the
--   connection; if very low-bitrate uploads were allowed then a Snap server
--   would be vulnerable to a trivial denial-of-service using a
--   \"slowloris\"-type attack
--
-- * the minimum number of seconds which must elapse before we start killing
--   uploads for having too low an upload rate.
--
-- * the amount of time we should wait before timing out the connection
--   whenever we receive input from the client.
data UploadPolicy = UploadPolicy {
      processFormInputs    :: Bool
    , maximumFormInputSize :: Int
    , minimumUploadRate    :: Double
    , minimumUploadSeconds :: Int
    , uploadTimeout        :: Int
} deriving (Show, Eq)


------------------------------------------------------------------------------
defaultUploadPolicy :: UploadPolicy
defaultUploadPolicy = UploadPolicy True maxSize minRate minSeconds tout
  where
    maxSize    = 2^(18::Int)
    minRate    = 1000
    minSeconds = 10
    tout       = 20


------------------------------------------------------------------------------
-- | Does this upload policy stipulate that we want to treat parts without
--   filenames as form input?
doProcessFormInputs :: UploadPolicy -> Bool
doProcessFormInputs = processFormInputs


------------------------------------------------------------------------------
-- | Set the upload policy for treating parts without filenames as form input.
setProcessFormInputs :: Bool -> UploadPolicy -> UploadPolicy
setProcessFormInputs b u = u { processFormInputs = b }


------------------------------------------------------------------------------
-- | Get the maximum size of a form input which will be read into our
--   'rqParams' map.
getMaximumFormInputSize :: UploadPolicy -> Int
getMaximumFormInputSize = maximumFormInputSize


------------------------------------------------------------------------------
-- | Set the maximum size of a form input which will be read into our
--   'rqParams' map.
setMaximumFormInputSize :: Int -> UploadPolicy -> UploadPolicy
setMaximumFormInputSize s u = u { maximumFormInputSize = s }


------------------------------------------------------------------------------
-- | Get the minimum rate (in /bytes\/second/) a client must maintain before
--   we kill the connection.
getMinimumUploadRate :: UploadPolicy -> Double
getMinimumUploadRate = minimumUploadRate


------------------------------------------------------------------------------
-- | Set the minimum rate (in /bytes\/second/) a client must maintain before
--   we kill the connection.
setMinimumUploadRate :: Double -> UploadPolicy -> UploadPolicy
setMinimumUploadRate s u = u { minimumUploadRate = s }


------------------------------------------------------------------------------
-- | Get the amount of time which must elapse before we begin enforcing the
--   upload rate minimum
getMinimumUploadSeconds :: UploadPolicy -> Int
getMinimumUploadSeconds = minimumUploadSeconds


------------------------------------------------------------------------------
-- | Set the amount of time which must elapse before we begin enforcing the
--   upload rate minimum
setMinimumUploadSeconds :: Int -> UploadPolicy -> UploadPolicy
setMinimumUploadSeconds s u = u { minimumUploadSeconds = s }


------------------------------------------------------------------------------
-- | Get the \"upload timeout\". Whenever input is received from the client,
--   the connection timeout is set this many seconds in the future.
getUploadTimeout :: UploadPolicy -> Int
getUploadTimeout = uploadTimeout


------------------------------------------------------------------------------
-- | Set the upload timeout.
setUploadTimeout :: Int -> UploadPolicy -> UploadPolicy
setUploadTimeout s u = u { uploadTimeout = s }


------------------------------------------------------------------------------
-- | Upload policy can be set on an \"general\" basis (using 'UploadPolicy'),
--   but handlers can also make policy decisions on individual files\/parts
--   uploaded. For each part uploaded, handlers can decide:
--
-- * whether to allow the file upload at all
--
-- * the maximum size of uploaded files, if allowed
data PartUploadPolicy = PartUploadPolicy {
      _maximumFileSize :: Maybe Int64
} deriving (Show, Eq)


------------------------------------------------------------------------------
-- | Disallows the file to be uploaded.
disallow :: PartUploadPolicy
disallow = PartUploadPolicy Nothing


------------------------------------------------------------------------------
-- | Allows the file to be uploaded, with maximum size /n/.
allowWithMaximumSize :: Int64 -> PartUploadPolicy
allowWithMaximumSize = PartUploadPolicy . Just


------------------------------------------------------------------------------
handleFileUploads ::
       (MonadSnap m) =>
       FilePath                       -- ^ temporary directory
    -> UploadPolicy                   -- ^ general upload policy
    -> (PartInfo -> PartUploadPolicy) -- ^ chooses policy given information
                                      -- about a file to be uploaded
    -> ([(PartInfo, Either PolicyViolationException FilePath)] -> m a)
    -> m a
handleFileUploads tmpdir uploadPolicy partPolicy handler = do
    uploadedFiles <- newUploadedFiles

    (do
        xs <- handleMultipart uploadPolicy (iter uploadedFiles)
        handler xs
        ) `finally` (cleanupUploadedFiles uploadedFiles)

  where
    iter uploadedFiles partInfo = maybe disallowed takeIt mbFs
      where
        ctText = partContentType partInfo
        fnText = fromMaybe "" $ partFileName partInfo

        ct = TE.decodeUtf8 ctText
        fn = TE.decodeUtf8 fnText

        (PartUploadPolicy mbFs) = partPolicy partInfo

        retVal (_,x) = (partInfo, Right x)

        takeIt maxSize = do
            let it = fmap retVal $
                     joinI' $
                     takeNoMoreThan maxSize $$
                     fileReader uploadedFiles tmpdir partInfo

            it `catches` [ Handler $ \(_ :: TooManyBytesReadException) ->
                                     (skipToEof >> tooMany maxSize)
                         , Handler $ \(e :: SomeException) -> throw e
                         ]

        tooMany maxSize =
            return ( partInfo
                   , Left $ PolicyViolationException
                          $ T.concat [ "File \""
                                     , fn
                                     , "\" exceeded maximum allowable size "
                                     , T.pack $ show maxSize ] )

        disallowed =
            return ( partInfo
                   , Left $ PolicyViolationException
                          $ T.concat [ "Policy disallowed upload of file \""
                                     , fn
                                     , "\" with content-type \""
                                     , ct
                                     , "\"" ] )


------------------------------------------------------------------------------
-- | Given an upload policy and a function to consume uploaded \"parts\",
-- consume a request body uploaded with @Content-type: multipart/form-data@.
-- Normally most users will want to use 'handleFileUploads' (which writes
-- uploaded files to a temporary directory and passes their names to a given
-- handler) rather than this function; the lower-level 'handleMultipart'
-- function should be used if you want to stream uploaded files to your own
-- iteratee function.
--
-- If the request's @Content-type@ was not \"@multipart/formdata@\", this
-- function skips processing using 'pass'.
--
-- If the client's upload rate passes below the configured minimum, this
-- function throws a 'RateTooSlowException'.
--
-- If the given 'UploadPolicy' stipulates that you wish form inputs to be
-- placed in the 'rqParams' parameter map, and a form input exceeds the maximum
-- allowable size, this function will throw a 'PolicyViolationException'.
--
-- If an uploaded part contains MIME headers longer than a fixed internal
-- threshold (currently 32KB), this function will throw a 'BadPartException'.
--
-- TODO: examples
handleMultipart ::
       (MonadSnap m) =>
       UploadPolicy
    -> (PartInfo -> Iteratee ByteString IO a)   -- ^ part processor
    -> m [a]
handleMultipart uploadPolicy origPartHandler = do
    hdrs <- liftM headers getRequest
    let (ct, mbBoundary) = getContentType hdrs

    tickleTimeout <- getTimeoutAction
    let bumpTimeout = tickleTimeout $ uploadTimeout uploadPolicy

    let partHandler = if doProcessFormInputs uploadPolicy
                        then captureVariableOrReadFile
                                 (getMaximumFormInputSize uploadPolicy)
                                 origPartHandler
                        else (\p -> fmap File (origPartHandler p))

    -- not well-formed multipart? bomb out.
    when (ct /= "multipart/form-data") $ do
        debug $ "handleMultipart called with content-type=" ++ S.unpack ct
                  ++ ", passing"
        pass

    when (isNothing mbBoundary) $
         throw $ BadPartException $
         "got multipart/form-data without boundary"

    let boundary = fromJust mbBoundary
    captures <- runRequestBody (iter bumpTimeout boundary partHandler `catch`
                                errHandler)

    procCaptures [] captures

  where
    iter bump boundary ph = killIfTooSlow
                              bump
                              (minimumUploadRate uploadPolicy)
                              (minimumUploadSeconds uploadPolicy)
                              (internalHandleMultipart boundary ph)

    errHandler (e :: SomeException) = skipToEof >> (lift $ throw e)

    ins k v = Map.insertWith' (\a b -> Prelude.head a : b) k [v]

    procCaptures l [] = return $ reverse l
    procCaptures l ((File x):xs) = procCaptures (x:l) xs
    procCaptures l ((Capture k v):xs) = do
        modifyRequest $ rqModifyParams (ins k v)
        procCaptures l xs


------------------------------------------------------------------------------
captureVariableOrReadFile ::
       Int                                     -- ^ maximum size of form input
    -> (PartInfo -> Iteratee ByteString IO a)  -- ^ file reading code
    -> (PartInfo -> Iteratee ByteString IO (Capture a))
captureVariableOrReadFile maxSize fileHandler partInfo =
    case partFileName partInfo of
      Nothing -> iter
      _       -> liftM File $ fileHandler partInfo
  where
    iter = varIter `catchError` handler

    fieldName = partFieldName partInfo

    varIter = do
        var <- liftM S.concat $
               joinI' $
               takeNoMoreThan (fromIntegral maxSize) $$ consume
        return $ Capture fieldName var

    handler e = do
        let m = fromException e :: Maybe TooManyBytesReadException
        case m of
          Nothing -> throwError e
          Just _  -> throwError $ PolicyViolationException $
                     T.concat [ "form input '"
                              , TE.decodeUtf8 fieldName
                              , "' exceeded maximum permissible size ("
                              , T.pack $ show maxSize
                              , " bytes)" ]


------------------------------------------------------------------------------
data Capture a = Capture ByteString ByteString
               | File a
  deriving (Show)


------------------------------------------------------------------------------
-- private exports follow. FIXME: organize
------------------------------------------------------------------------------


------------------------------------------------------------------------------
fileReader :: UploadedFiles
           -> FilePath
           -> PartInfo
           -> Iteratee ByteString IO (PartInfo, FilePath)
fileReader uploadedFiles tmpdir partInfo = do
    (fn, h) <- openFileForUpload uploadedFiles tmpdir
    let i = iterateeDebugWrapper "fileReader" $ iter fn h
    i `catch` \(e::SomeException) -> throwError e

  where
    iter fileName h = do
        iterHandle h
        debug "fileReader: closing active file"
        closeActiveFile uploadedFiles
        return (partInfo, fileName)


------------------------------------------------------------------------------
internalHandleMultipart ::
       ByteString                              -- ^ boundary value
    -> (PartInfo -> Iteratee ByteString IO a)  -- ^ part processor
    -> Iteratee ByteString IO [a]
internalHandleMultipart boundary clientHandler = go `catch` errorHandler

  where
    --------------------------------------------------------------------------
    errorHandler :: SomeException -> Iteratee ByteString IO a
    errorHandler e = do
        skipToEof
        throwError e

    --------------------------------------------------------------------------
    go = do
        -- swallow the first boundary
        _ <- iterParser $ parseFirstBoundary boundary
        step <- iterateeDebugWrapper "kmp" $
                (kmpEnumeratee (fullBoundary boundary) $$ processParts iter)
        liftM concat $ lift $ run_ $ returnI step

    --------------------------------------------------------------------------
    pBoundary b = Atto.try $ do
      _ <- string "--"
      string b

    --------------------------------------------------------------------------
    fullBoundary b       = S.concat ["\r\n", "--", b]
    pLine                = takeWhile (not . isEndOfLine . c2w) <* eol
    takeLine             = pLine *> pure ()
    parseFirstBoundary b = pBoundary b <|> (takeLine *> parseFirstBoundary b)


    --------------------------------------------------------------------------
    takeHeaders = hdrs `catchError` handler
      where
        hdrs = liftM toHeaders $
               iterateeDebugWrapper "header parser" $
               joinI' $
               takeNoMoreThan mAX_HDRS_SIZE $$
               iterParser pHeadersWithSeparator

        handler e = do
            let m = fromException e :: Maybe TooManyBytesReadException
            case m of
              Nothing -> throwError e
              Just _  -> throwError $ BadPartException $
                         "headers exceeded maximum size"

    --------------------------------------------------------------------------
    iter = do
        hdrs <- takeHeaders

        -- are we using mixed?
        let (contentType, mboundary) = getContentType hdrs

        let (fieldName, fileName) = getFieldName hdrs

        if contentType == "multipart/mixed"
          then maybe (throwError $ BadPartException $
                      "got multipart/mixed without boundary")
                     (processMixed fieldName)
                     mboundary
          else do
              let info = PartInfo fieldName fileName contentType
              liftM (:[]) $ clientHandler info


    --------------------------------------------------------------------------
    processMixed fieldName mixedBoundary = do
        -- swallow the first boundary
        _ <- iterParser $ parseFirstBoundary mixedBoundary
        step <- iterateeDebugWrapper "kmp" $
                (kmpEnumeratee (fullBoundary mixedBoundary) $$
                 processParts (mixedIter fieldName))
        lift $ run_ $ returnI step


    --------------------------------------------------------------------------
    mixedIter fieldName = do
        hdrs <- takeHeaders

        let (contentType, _) = getContentType hdrs
        let (_, fileName)    = getFieldName hdrs

        let info = PartInfo fieldName fileName contentType
        clientHandler info


------------------------------------------------------------------------------
getContentType :: Headers
               -> (ByteString, Maybe ByteString)
getContentType hdrs = (contentType, boundary)
  where
    contentTypeValue = fromMaybe "text/plain" $
                       getHeader "content-type" hdrs

    eCT = fullyParse contentTypeValue pContentTypeWithParameters
    (contentType, params) = either (const ("text/plain", [])) id eCT

    boundary = findParam "boundary" params


------------------------------------------------------------------------------
getFieldName :: Headers -> (ByteString, Maybe ByteString)
getFieldName hdrs = (fieldName, fileName)
  where
    contentDispositionValue = fromMaybe "" $
                              getHeader "content-disposition" hdrs

    eDisposition = fullyParse contentDispositionValue pValueWithParameters

    (_, dispositionParameters) =
        either (const ("", [])) id eDisposition

    fieldName = fromMaybe "" $ findParam "name" dispositionParameters

    fileName = findParam "filename" dispositionParameters


------------------------------------------------------------------------------
findParam :: (Eq a) => a -> [(a, b)] -> Maybe b
findParam p = fmap snd . find ((== p) . fst)


------------------------------------------------------------------------------
-- | Given a 'MatchInfo' stream which is partitioned by boundary values, read
-- up until the next boundary and send all of the chunks into the wrapped
-- iteratee
processPart :: (Monad m) => Enumeratee MatchInfo ByteString m a
processPart = checkDone go
  where
    go :: (Monad m) => (Stream ByteString -> Iteratee ByteString m a)
                    -> Iteratee MatchInfo m (Step ByteString m a)
    go k = I.head >>= maybe (finish k) (process k)

    -- called when outer stream is EOF
    finish :: (Monad m) => (Stream ByteString -> Iteratee ByteString m a)
                        -> Iteratee MatchInfo m (Step ByteString m a)
    finish k = lift $ runIteratee $ k EOF

    -- no match ==> pass the stream chunk along
    process :: (Monad m) => (Stream ByteString -> Iteratee ByteString m a)
                         -> MatchInfo
                         -> Iteratee MatchInfo m (Step ByteString m a)
    process k (NoMatch s) = do
      step <- lift $ runIteratee $ k $ Chunks [s]
      checkDone go step

    process k (Match _) = lift $ runIteratee $ k EOF


------------------------------------------------------------------------------
-- | Assuming we've already identified the boundary value and run
-- 'kmpEnumeratee' to split the input up into parts which match and parts which
-- don't, run the given 'ByteString' iteratee over each part and grab a list of
-- the resulting values.
processParts :: Iteratee ByteString IO a
             -> Iteratee MatchInfo IO [a]
processParts partIter = iterateeDebugWrapper "processParts" $ go D.empty
  where
    iter = do
        isLast <- bParser
        if isLast
          then return Nothing
          else do
            x <- partIter
            skipToEof
            return $ Just x

    go soFar = do
      b <- isEOF

      if b
        then return $ D.toList soFar
        else do
           -- processPart $$ iter :: Iteratee MatchInfo m (Step ByteString m a)
           innerStep <- processPart $$ iter

           -- output :: Maybe a
           output <- lift $ run_ $ returnI innerStep

           case output of
             Just x  -> go (D.append soFar $ D.singleton x)
             Nothing -> return $ D.toList soFar

    bParser = iterateeDebugWrapper "boundary debugger" $ iterParser $ pBoundaryEnd

    pBoundaryEnd = (eol *> pure False) <|> (string "--" *> pure True)


------------------------------------------------------------------------------
eol :: Parser ByteString
eol = (string "\n") <|> (string "\r\n")


------------------------------------------------------------------------------
pHeadersWithSeparator :: Parser [(ByteString,ByteString)]
pHeadersWithSeparator = pHeaders <* crlf


------------------------------------------------------------------------------
toHeaders :: [(ByteString,ByteString)] -> Headers
toHeaders kvps = foldl' f Map.empty kvps'
  where
    kvps'     = map (first toCI . second (:[])) kvps
    f m (k,v) = Map.insertWith' (flip (++)) k v m


------------------------------------------------------------------------------
mAX_HDRS_SIZE :: Int64
mAX_HDRS_SIZE = 32768


------------------------------------------------------------------------------
-- We need some code to keep track of the files we have already successfully
-- created in case an exception is thrown by the request body enumerator or one
-- of the client iteratees.
data UploadedFilesState = UploadedFilesState {
      -- | This is the file which is currently being written to. If the calling
      -- function gets an exception here, it is responsible for closing and
      -- deleting this file.
      _currentFile :: Maybe (FilePath, Handle)

      -- | .. and these files have already been successfully read and closed.
    , _alreadyReadFiles :: [FilePath]
}


------------------------------------------------------------------------------
emptyUploadedFilesState :: UploadedFilesState
emptyUploadedFilesState = UploadedFilesState Nothing []


------------------------------------------------------------------------------
newtype UploadedFiles = UploadedFiles (IORef UploadedFilesState)


------------------------------------------------------------------------------
newUploadedFiles :: MonadIO m => m UploadedFiles
newUploadedFiles = liftM UploadedFiles $
                   liftIO $ newIORef emptyUploadedFilesState


------------------------------------------------------------------------------
cleanupUploadedFiles :: (MonadIO m) => UploadedFiles -> m ()
cleanupUploadedFiles (UploadedFiles stateRef) = liftIO $ do
    state <- readIORef stateRef
    killOpenFile state
    mapM_ killFile $ _alreadyReadFiles state
    writeIORef stateRef emptyUploadedFilesState

  where
    killFile = eatException . removeFile

    killOpenFile state = maybe (return ())
                               (\(fp,h) -> do
                                    eatException $ hClose h
                                    eatException $ removeFile fp)
                               (_currentFile state)


------------------------------------------------------------------------------
openFileForUpload :: (MonadIO m) =>
                     UploadedFiles
                  -> FilePath
                  -> m (FilePath, Handle)
openFileForUpload ufs@(UploadedFiles stateRef) tmpdir = liftIO $ do
    state <- readIORef stateRef

    -- It should be an error to open a new file with this interface if there is
    -- already a file handle active.
    when (isJust $ _currentFile state) $ do
        cleanupUploadedFiles ufs
        throw $ GenericFileUploadException alreadyOpenMsg

    fph <- openTempFile tmpdir "snap-"

    writeIORef stateRef $ state { _currentFile = Just fph }
    return fph

  where
    alreadyOpenMsg =
        T.concat [ "Internal error! UploadedFiles: "
                 , "opened new file with pre-existing open handle" ]


------------------------------------------------------------------------------
closeActiveFile :: (MonadIO m) => UploadedFiles -> m ()
closeActiveFile (UploadedFiles stateRef) = liftIO $ do
    state <- readIORef stateRef
    let m = _currentFile state
    maybe (return ())
          (\(fp,h) -> do
               eatException $ hClose h
               writeIORef stateRef $
                 state { _currentFile = Nothing
                       , _alreadyReadFiles = fp:(_alreadyReadFiles state) })
          m


------------------------------------------------------------------------------
eatException :: (MonadCatchIO m) => m a -> m ()
eatException m =
    (m >> return ()) `catch` (\(_ :: SomeException) -> return ())