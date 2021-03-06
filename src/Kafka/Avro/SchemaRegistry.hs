{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}

module Kafka.Avro.SchemaRegistry
( schemaRegistry, loadSchema, sendSchema
, schemaRegistry_
, loadSubjectSchema
, getGlobalConfig, getSubjectConfig
, getVersions, isCompatible
, getSubjects
, SchemaId(..), Subject(..)
, SchemaRegistry, SchemaRegistryError(..)
, Schema(..)
, Compatibility(..), Version(..)
) where

import           Control.Arrow           (first)
import           Control.Exception       (throwIO)
import           Control.Lens            (view, (&), (.~), (^.))
import           Control.Monad           (void)
import           Control.Monad.IO.Class  (MonadIO, liftIO)
import           Data.Aeson
import           Data.Aeson.Types        (typeMismatch)
import           Data.Avro.Schema.Schema (Schema (..), typeName)
import           Data.Bifunctor          (bimap)
import           Data.Cache              as C
import           Data.Hashable           (Hashable)
import qualified Data.HashMap.Lazy       as HM
import           Data.Int                (Int32)
import           Data.String             (IsString)
import           Data.Text               (Text, append, cons, unpack)
import qualified Data.Text.Encoding      as Text
import qualified Data.Text.Lazy.Encoding as LText
import           Data.Word               (Word32)
import           GHC.Exception           (SomeException, displayException, fromException)
import           GHC.Generics            (Generic)
import           Network.HTTP.Client     (HttpException (..), HttpExceptionContent (..), Manager, defaultManagerSettings, newManager)
import qualified Network.Wreq            as Wreq

newtype SchemaId = SchemaId { unSchemaId :: Int32} deriving (Eq, Ord, Show, Hashable)
newtype SchemaName = SchemaName Text deriving (Eq, Ord, IsString, Show, Hashable)

newtype Subject = Subject { unSubject :: Text} deriving (Eq, Show, IsString, Ord, Generic, Hashable)

newtype RegisteredSchema = RegisteredSchema { unRegisteredSchema :: Schema} deriving (Generic, Show)

newtype Version = Version { unVersion :: Word32 } deriving (Eq, Ord, Show, Hashable)

data Compatibility = NoCompatibility
                   | FullCompatibility
                   | ForwardCompatibility
                   | BackwardCompatibility
                   deriving (Eq, Show, Ord)

data SchemaRegistry = SchemaRegistry
  { srCache        :: Cache SchemaId Schema
  , srReverseCache :: Cache (Subject, SchemaName) SchemaId
  , srBaseUrl      :: String
  , srAuth         :: Maybe Wreq.Auth
  }

data SchemaRegistryError = SchemaRegistryConnectError String
                         | SchemaRegistryLoadError SchemaId
                         | SchemaRegistrySchemaNotFound SchemaId
                         | SchemaRegistrySendError String
                         deriving (Show, Eq)

schemaRegistry :: MonadIO m => String -> m SchemaRegistry
schemaRegistry = schemaRegistry_ Nothing

schemaRegistry_ :: MonadIO m => Maybe Wreq.Auth -> String -> m SchemaRegistry
schemaRegistry_ auth url = liftIO $
    SchemaRegistry
    <$> newCache Nothing
    <*> newCache Nothing
    <*> pure url
    <*> pure auth


loadSchema :: MonadIO m => SchemaRegistry -> SchemaId -> m (Either SchemaRegistryError Schema)
loadSchema sr sid = do
  sc <- cachedSchema sr sid
  case sc of
    Just s  -> return (Right s)
    Nothing -> liftIO $ do
      res <- getSchemaById sr sid
      traverse ((\schema -> schema <$ cacheSchema sr sid schema) . unRegisteredSchema) res

loadSubjectSchema :: MonadIO m => SchemaRegistry -> Subject -> Version -> m (Either SchemaRegistryError Schema)
loadSubjectSchema sr (Subject sbj) (Version version) = do
    let url = (srBaseUrl sr) ++ "/subjects/" ++ unpack sbj ++ "/versions/" ++ show version
    resp    <- liftIO $ Wreq.getWith (wreqOpts sr) url
    wrapped <- pure $ bimap wrapError (view Wreq.responseBody) (Wreq.asValue resp)

    schema   <- getData "schema" wrapped
    schemaId <- getData "id" wrapped

    case (,) <$> schema <*> schemaId of
      Left err                                    -> return $ Left err
      Right ((RegisteredSchema schema), schemaId) -> cacheSchema sr schemaId schema *> (return $ Right schema)
  where
    getData :: (MonadIO m, FromJSON a) => String -> Either e Value -> m (Either e a)
    getData key = either (pure . Left) (viewData key)

    viewData :: (MonadIO m, FromJSON a) => String -> Value -> m (Either e a)
    viewData key value = liftIO $ either (throwIO . Wreq.JSONError)
                                         (return . return)
                                         (toData value)

    toData :: FromJSON a => Value -> Either String a
    toData value = case fromJSON value of
                     Success a -> Right a
                     Error e   -> Left e

sendSchema :: MonadIO m => SchemaRegistry -> Subject -> Schema -> m (Either SchemaRegistryError SchemaId)
sendSchema sr subj sc = do
  sid <- cachedId sr subj schemaName
  case sid of
    Just sid' -> return (Right sid')
    Nothing   -> do
      res <- liftIO $ putSchema sr subj (RegisteredSchema sc)
      void $ traverse (cacheId sr subj schemaName) res
      void $ traverse (\sid' -> cacheSchema sr sid' sc) res
      pure res
  where
    schemaName = fullTypeName sc

getVersions :: MonadIO m => SchemaRegistry -> Subject -> m (Either SchemaRegistryError [Version])
getVersions sr (Subject sbj) = do
  let url = (srBaseUrl sr) ++ "/subjects/" ++ unpack sbj ++ "/versions"
  resp <- liftIO $ Wreq.getWith (wreqOpts sr) url
  pure $ bimap wrapError (fmap Version . view Wreq.responseBody) (Wreq.asJSON resp)

isCompatible :: MonadIO m => SchemaRegistry -> Subject -> Version -> Schema -> m (Either SchemaRegistryError Bool)
isCompatible sr (Subject sbj) (Version version) schema = do
  let url  = (srBaseUrl sr) ++ "/compatibility/subjects/" ++ unpack sbj ++ "/versions/" ++ show version
  resp     <- liftIO $ Wreq.postWith (wreqOpts sr) url (toJSON $ RegisteredSchema schema)
  wrapped  <- pure $ bimap wrapError (view Wreq.responseBody) (Wreq.asValue resp)
  either (return . Left) getCompatibility wrapped
  where
    getCompatibility :: MonadIO m => Value -> m (Either e Bool)
    getCompatibility = liftIO . maybe (throwIO $ Wreq.JSONError "Missing key 'is_compatible' in Schema Registry response") (return . return) . viewCompatibility

    viewCompatibility :: Value -> Maybe Bool
    viewCompatibility (Object obj) = HM.lookup "is_compatible" obj >>= toBool
    viewCompatibility _            = Nothing

    toBool :: Value -> Maybe Bool
    toBool (Bool b) = Just b
    toBool _        = Nothing

getGlobalConfig :: MonadIO m => SchemaRegistry -> m (Either SchemaRegistryError Compatibility)
getGlobalConfig sr = do
  let url = (srBaseUrl sr) ++ "/config"
  resp <- liftIO $ Wreq.getWith (wreqOpts sr) url
  pure $ bimap wrapError (view Wreq.responseBody) (Wreq.asJSON resp)

getSubjectConfig :: MonadIO m => SchemaRegistry -> Subject -> m (Either SchemaRegistryError Compatibility)
getSubjectConfig sr (Subject sbj) = do
  let url = (srBaseUrl sr) ++ "/config/" ++ unpack sbj
  resp <- liftIO $ Wreq.getWith (wreqOpts sr) url
  pure $ bimap wrapError (view Wreq.responseBody) (Wreq.asJSON resp)

getSubjects :: MonadIO m => SchemaRegistry -> m (Either SchemaRegistryError [Subject])
getSubjects sr = do
  let url = (srBaseUrl sr) ++ "/subjects"
  resp <- liftIO $ Wreq.getWith (wreqOpts sr) url
  pure $ bimap wrapError (fmap Subject . view Wreq.responseBody) (Wreq.asJSON resp)

------------------ PRIVATE: HELPERS --------------------------------------------

wreqOpts :: SchemaRegistry -> Wreq.Options
wreqOpts sr =
  let
    accept       = ["application/vnd.schemaregistry.v1+json", "application/vnd.schemaregistry+json", "application/json"]
    acceptHeader = Wreq.header "Accept" .~ accept
    authHeader   = Wreq.auth .~ srAuth sr
  in Wreq.defaults & acceptHeader & authHeader

getSchemaById :: SchemaRegistry -> SchemaId -> IO (Either SchemaRegistryError RegisteredSchema)
getSchemaById sr sid@(SchemaId i) = do
  let
    baseUrl   = srBaseUrl sr
    schemaUrl = baseUrl ++ "/schemas/ids/" ++ show i
  resp <- Wreq.getWith (wreqOpts sr) schemaUrl
  pure $ bimap (const (SchemaRegistryLoadError sid)) (view Wreq.responseBody) (Wreq.asJSON resp)

putSchema :: SchemaRegistry -> Subject -> RegisteredSchema -> IO (Either SchemaRegistryError SchemaId)
putSchema sr (Subject sbj) schema = do
  let
    baseUrl   = srBaseUrl sr
    schemaUrl = baseUrl ++ "/subjects/" ++ unpack sbj ++ "/versions"
  resp <- Wreq.postWith (wreqOpts sr) schemaUrl (toJSON schema)
  pure $ bimap wrapError (view Wreq.responseBody) (Wreq.asJSON resp)

fromHttpError :: HttpException -> (HttpExceptionContent -> SchemaRegistryError) -> SchemaRegistryError
fromHttpError err f = case err of
  InvalidUrlException fld err'                      -> SchemaRegistryConnectError (fld ++ ": " ++ err')
  HttpExceptionRequest _ (ConnectionFailure err)    -> SchemaRegistryConnectError (displayException err)
  HttpExceptionRequest _ ConnectionTimeout          -> SchemaRegistryConnectError (displayException err)
  HttpExceptionRequest _ ProxyConnectException{}    -> SchemaRegistryConnectError (displayException err)
  HttpExceptionRequest _ ConnectionClosed           -> SchemaRegistryConnectError (displayException err)
  HttpExceptionRequest _ (InvalidDestinationHost _) -> SchemaRegistryConnectError (displayException err)
  HttpExceptionRequest _ TlsNotSupported            -> SchemaRegistryConnectError (displayException err)
#if MIN_VERSION_http_client(0,5,7)
  HttpExceptionRequest _ (InvalidProxySettings _)   -> SchemaRegistryConnectError (displayException err)
#endif
  HttpExceptionRequest _ err'                       -> f err'

wrapError :: SomeException -> SchemaRegistryError
wrapError someErr = case fromException someErr of
  Nothing      -> SchemaRegistrySendError (displayException someErr)
  Just httpErr -> fromHttpError httpErr (\_ -> SchemaRegistrySendError (displayException someErr))

---------------------------------------------------------------------
fullTypeName :: Schema -> SchemaName
fullTypeName r = SchemaName $ typeName r

cachedSchema :: MonadIO m => SchemaRegistry -> SchemaId -> m (Maybe Schema)
cachedSchema sr k = liftIO $ C.lookup (srCache sr) k
{-# INLINE cachedSchema #-}

cacheSchema :: MonadIO m => SchemaRegistry -> SchemaId -> Schema -> m ()
cacheSchema sr k v = liftIO $ C.insert (srCache sr) k v
{-# INLINE cacheSchema #-}

cachedId :: MonadIO m => SchemaRegistry -> Subject -> SchemaName -> m (Maybe SchemaId)
cachedId sr subj scn = liftIO $ C.lookup (srReverseCache sr) (subj, scn)
{-# INLINE cachedId #-}

cacheId :: MonadIO m => SchemaRegistry -> Subject -> SchemaName -> SchemaId -> m ()
cacheId sr subj scn sid = liftIO $ C.insert (srReverseCache sr) (subj, scn) sid
{-# INLINE cacheId #-}

instance FromJSON RegisteredSchema where
  parseJSON (Object v) =
    withObject "expected schema" (\obj -> do
      sch <- obj .: "schema"
      maybe mempty (return . RegisteredSchema) (decode $ LText.encodeUtf8 sch)
    ) (Object v)

  parseJSON _ = mempty

instance ToJSON RegisteredSchema where
  toJSON (RegisteredSchema v) = object ["schema" .= LText.decodeUtf8 (encode $ toJSON v)]

instance FromJSON SchemaId where
  parseJSON (Object v) = SchemaId <$> v .: "id"
  parseJSON _          = mempty

instance FromJSON Compatibility where
  parseJSON = withObject "Compatibility" $ \v -> do
    compatibility <- v .: "compatibilityLevel"
    case compatibility of
      "NONE"     -> return $ NoCompatibility
      "FULL"     -> return $ FullCompatibility
      "FORWARD"  -> return $ ForwardCompatibility
      "BACKWARD" -> return $ BackwardCompatibility
      _          -> typeMismatch "Compatibility" compatibility
