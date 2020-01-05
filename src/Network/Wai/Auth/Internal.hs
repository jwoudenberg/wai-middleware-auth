{-# OPTIONS_HADDOCK hide, not-home #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Network.Wai.Auth.Internal
  ( OAuth2TokenBinary(..)
  , encodeToken
  , decodeToken
  , oauth2Login
  , oauth2RefreshLogin
  ) where

import           Data.Binary                          (Binary(get, put), encode,
                                                      decodeOrFail)
import qualified Data.ByteString                      as S
import qualified Data.ByteString.Char8                as S8 (pack)
import qualified Data.ByteString.Lazy                 as SL
import           Data.Int
import qualified Data.Text                            as T
import           Data.Text.Encoding                   (encodeUtf8,
                                                       decodeUtf8With)
import           Data.Text.Encoding.Error             (lenientDecode)
import           Foreign.C.Types                      (CTime (..))
import           Network.HTTP.Client                  (Manager)
import           Network.HTTP.Types                   (Status, status303,
                                                       status403, status404,
                                                       status501)
import qualified Network.OAuth.OAuth2                 as OA2
import           Network.Wai                          (Request, Response,
                                                       queryString, responseLBS)
import           Network.Wai.Middleware.Auth.Provider
import           System.PosixCompat.Time              (epochTime)
import qualified URI.ByteString                       as U
import           URI.ByteString                       (URI)

decodeToken :: S.ByteString -> Either String OA2.OAuth2Token
decodeToken bs =
  case decodeOrFail $ SL.fromStrict bs of
    Right (_, _, token) -> Right $ unOAuth2TokenBinary token
    Left (_, _, err) -> Left err

encodeToken :: OA2.OAuth2Token -> S.ByteString
encodeToken = SL.toStrict . encode . OAuth2TokenBinary

newtype OAuth2TokenBinary =
  OAuth2TokenBinary { unOAuth2TokenBinary :: OA2.OAuth2Token }
  deriving (Show)

instance Binary OAuth2TokenBinary where
  put (OAuth2TokenBinary token) = do
    put $ OA2.atoken $ OA2.accessToken token
    put $ OA2.rtoken <$> OA2.refreshToken token
    put $ OA2.expiresIn token
    put $ OA2.tokenType token
    put $ OA2.idtoken <$> OA2.idToken token
  get = do
    accessToken <- OA2.AccessToken <$> get
    refreshToken <- fmap OA2.RefreshToken <$> get
    expiresIn <- get
    tokenType <- get
    idToken <- fmap OA2.IdToken <$> get
    pure $ OAuth2TokenBinary $
      OA2.OAuth2Token accessToken refreshToken expiresIn tokenType idToken

oauth2Login
  :: OA2.OAuth2
  -> Manager
  -> Maybe [T.Text]
  -> T.Text
  -> Request 
  -> [T.Text]
  -> (AuthLoginState -> IO Response)
  -> (Status -> S.ByteString -> IO Response)
  -> IO Response
oauth2Login oauth2 man oa2Scope providerName req suffix onSuccess onFailure = 
  case suffix of
    [] -> do
      let scope = (encodeUtf8 . T.intercalate ",") <$> oa2Scope
      let redirectUrl =
            getRedirectURI $
            appendQueryParams
              (OA2.authorizationUrl oauth2)
              (maybe [] ((: []) . ("scope", )) scope)
      return $
        responseLBS
          status303
          [("Location", redirectUrl)]
          "Redirect to OAuth2 Authentication server"
    ["complete"] ->
      let params = queryString req
      in case lookup "code" params of
            Just (Just code) -> do
              eRes <- OA2.fetchAccessToken man oauth2 $ getExchangeToken code
              case eRes of
                Left err    -> onFailure status501 $ S8.pack $ show err
                Right token -> onSuccess $ encodeToken token
            _ ->
              case lookup "error" params of
                (Just (Just "access_denied")) ->
                  onFailure
                    status403
                    "User rejected access to the application."
                (Just (Just error_code)) ->
                  onFailure status501 $ "Received an error: " <> error_code
                (Just Nothing) ->
                  onFailure status501 $
                  "Unknown error connecting to " <>
                  encodeUtf8 providerName
                Nothing ->
                  onFailure
                    status404
                    "Page not found. Please continue with login."
    _ -> onFailure status404 "Page not found. Please continue with login."

oauth2RefreshLogin :: OA2.OAuth2 -> Manager -> AuthUser -> IO (Maybe AuthUser)
oauth2RefreshLogin oauth2 man user = 
  let loginState = authLoginState user
  in case decodeToken loginState of
    Left _ -> pure Nothing
    Right tokens -> do
      CTime now <- epochTime
      if tokenExpired user now tokens then
        case OA2.refreshToken tokens of
          Nothing -> pure Nothing
          Just refreshToken -> do
            rRes <- OA2.refreshAccessToken man oauth2 refreshToken
            case rRes of
              Left _ -> pure Nothing
              Right tokens' -> 
                let user' =
                      user {
                        authLoginState = encodeToken tokens',
                        authLoginTime = fromIntegral now
                      }
                in pure (Just user')
        else
          pure (Just user)

tokenExpired :: AuthUser -> Int64 -> OA2.OAuth2Token -> Bool
tokenExpired user now tokens =
  case OA2.expiresIn tokens of
    Nothing -> False
    Just expiresIn -> authLoginTime user + (fromIntegral expiresIn) < now

getExchangeToken :: S.ByteString -> OA2.ExchangeToken
getExchangeToken = OA2.ExchangeToken . decodeUtf8With lenientDecode

appendQueryParams :: URI -> [(S.ByteString, S.ByteString)] -> URI
appendQueryParams uri params =
  OA2.appendQueryParams params uri

getRedirectURI :: U.URIRef a -> S.ByteString
getRedirectURI = U.serializeURIRef'
