{-# LANGUAGE FlexibleInstances   #-}     
{-# LANGUAGE RecordWildCards   #-}     
{-# LANGUAGE OverloadedStrings #-}
-- | An OpenID connect provider.
--
-- OpenID Connect is a simple identity layer on top of the OAuth2 protocol.
-- Learn more about it here: <https://openid.net/connect/>
--
-- @since 0.2.3.0
module Network.Wai.Middleware.Auth.OIDC
  ( -- * Creating a provider
    OpenIDConnect
  , discover
  -- * Customizing a provider
  , oidcClientId
  , oidcClientSecret
  , oidcProviderInfo
  , oidcManager
  , oidcScopes
  , oidcAllowedSkew
  -- * Accessing session data
  , getAccessToken
  , getIdToken
  ) where

import           Control.Applicative                  ((<|>))
import qualified Crypto.JOSE                          as JOSE
import qualified Crypto.JWT                           as JWT
import           Control.Monad.Except                 (runExceptT)
import qualified Data.ByteString.Char8                as S8
import           Data.Function                        ((&))
import qualified Data.Time.Clock                      as Clock
import           Data.Traversable                     (for)
import qualified Data.Text                            as T
import qualified Data.Text.Lazy                       as TL
import qualified Data.Text.Lazy.Encoding              as TLE
import qualified Data.Vault.Lazy                      as Vault
import           Foreign.C.Types                      (CTime (..))
import qualified Lens.Micro                           as Lens
import qualified Lens.Micro.Extras                    as Lens.Extras
import           Network.HTTP.Simple                  (httpJSON,
                                                       getResponseBody,
                                                       parseRequestThrow)
import           Network.Wai.Middleware.Auth.OAuth2   (parseAbsoluteURI,
                                                      getAccessToken)
import qualified Network.OAuth.OAuth2                 as OA2
import           Network.HTTP.Client                  (Manager)
import           Network.HTTP.Client.TLS              (getGlobalManager)
import           Network.Wai                          (Request, vault)
import           Network.Wai.Auth.Internal            (Metadata(..),
                                                       decodeToken, encodeToken,
                                                       oauth2Login,
                                                       refreshTokens)
import           Network.Wai.Middleware.Auth.Provider
import           System.IO.Unsafe                     (unsafePerformIO)
import           System.PosixCompat.Time              (epochTime)
import qualified Text.Hamlet
import qualified URI.ByteString                       as U

-- | An Open ID Connect provider.
--
-- To create a value use `discover` to download configuration for an existing
-- provider, then use various setter functions to customize it.
--
-- @since 0.2.3.0
data OpenIDConnect
  = OpenIDConnect
      { oidcMetadata :: Metadata
      , oidcJwkSet :: JOSE.JWKSet
      -- | The client id this application is registered with at the Open ID
      -- Connect provider. The default is an empty string, you will need to
      -- overwrite this.
      --
      -- @since 0.2.3.0
      , oidcClientId :: T.Text
      -- | The client secret of this application. The default is an empty
      -- string, you will need to overwrite this.
      --
      -- @since 0.2.3.0
      , oidcClientSecret :: T.Text
      -- | The information for this provider. The default contains some
      -- placeholder texts. If you're using the provider screen you'll want to
      -- overwrite this.
      --
      -- @since 0.2.3.0
      , oidcProviderInfo :: ProviderInfo
      -- | The HTTP manager to use. Defaults to the global manager.
      --
      -- @since 0.2.3.0
      , oidcManager :: Manager
      -- | The scopes to set. Defaults to only the "openid" scope.
      --
      -- @since 0.2.3.0
      , oidcScopes :: [T.Text]
      -- | The amount of clock skew to allow when validating id tokens. Defaults
      -- to 0.
      --
      -- @since 0.2.3.0
      , oidcAllowedSkew :: Clock.NominalDiffTime
      }

instance AuthProvider OpenIDConnect where
  getProviderName _ = "oidc"
  getProviderInfo = oidcProviderInfo
  handleLogin oidc@OpenIDConnect {.. } req suffix renderUrl onSuccess onFailure = do
    oauth2 <- mkOauth2 oidc (Just renderUrl)
    oauth2Login
      oauth2
      oidcManager
      (Just oidcScopes)
      (getProviderName oidc)
      req
      suffix
      onSuccess
      onFailure
  refreshLoginState oidc req user =
    let loginState = authLoginState user
    in case decodeToken loginState of
      Left _ -> pure Nothing
      Right tokens -> do
        vRes <- validateIdToken' oidc tokens
        case vRes of
          Nothing -> do
            oauth2 <- mkOauth2 oidc Nothing
            rRes <- refreshTokens tokens (oidcManager oidc) oauth2
            case rRes of
              Nothing -> pure Nothing
              Just newTokens -> do
                v2Res <- validateIdToken' oidc newTokens
                case v2Res of
                  Nothing -> pure Nothing
                  Just claims -> do
                    CTime now <- epochTime
                    let newUser =
                          user {
                            authLoginState = encodeToken newTokens,
                            authLoginTime = fromIntegral now
                          }
                    pure (Just (storeClaims claims req, newUser))
          Just claims -> 
            pure (Just (storeClaims claims req, user))

-- | Fetch configuration for a provider from its discovery endpoint.
--
-- @since 0.2.3.0
discover :: T.Text -> IO OpenIDConnect
discover urlText = do
  base <- parseAbsoluteURI urlText
  let uri = base { U.uriPath = "/.well-known/openid-configuration" }
  metadata <- fetchMetadata uri
  jwkset <- fetchJWKSet (jwksUri metadata)
  manager <- getGlobalManager
  pure OpenIDConnect 
    { oidcClientId = ""
    , oidcClientSecret = ""
    , oidcMetadata = metadata
    , oidcJwkSet = jwkset
    , oidcProviderInfo = ProviderInfo "OpenID Connect Provider" "" ""
    , oidcManager = manager
    , oidcScopes = ["openid"]
    , oidcAllowedSkew = 0
    }

fetchMetadata :: U.URI -> IO Metadata
fetchMetadata metadataEndpoint = do
  req <- parseRequestThrow (S8.unpack $ U.serializeURIRef' metadataEndpoint) 
  getResponseBody <$> httpJSON req

fetchJWKSet :: T.Text -> IO JOSE.JWKSet
fetchJWKSet jwkSetEndpoint = do
  req <- parseRequestThrow (T.unpack jwkSetEndpoint) 
  getResponseBody <$> httpJSON req

mkOauth2 :: OpenIDConnect -> Maybe (Text.Hamlet.Render ProviderUrl) -> IO OA2.OAuth2
mkOauth2 OpenIDConnect {..} renderUrl = do
  callbackURI <- for renderUrl $ \render -> parseAbsoluteURI $ render (ProviderUrl ["complete"]) []
  pure OA2.OAuth2
        { oauthClientId = oidcClientId
        , oauthClientSecret = oidcClientSecret
        , oauthOAuthorizeEndpoint = authorizationEndpoint oidcMetadata
        , oauthAccessTokenEndpoint = tokenEndpoint oidcMetadata
        , oauthCallback = callbackURI
        }

validateIdToken :: OpenIDConnect -> OA2.IdToken -> IO (Either JWT.JWTError JWT.ClaimsSet)
validateIdToken oidc (OA2.IdToken idToken) = runExceptT $ do
  signedJwt <- JOSE.decodeCompact (TLE.encodeUtf8 $ TL.fromStrict idToken)
  JWT.verifyClaims (validationSettings oidc) (oidcJwkSet oidc) signedJwt

validateIdToken' :: OpenIDConnect -> OA2.OAuth2Token -> IO (Maybe JWT.ClaimsSet)
validateIdToken' oidc tokens = 
  case OA2.idToken tokens of
    Nothing -> pure Nothing
    Just idToken ->
      either (const Nothing) Just <$> validateIdToken oidc idToken

-- The validation of the ID token below is stricter then specified in the OIDC
-- spec, to make the job of validating tokens easier. If this is too limiting
-- for your user case please open an issue.
--
-- Full spec for ID token validation:
-- https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
--
-- Ways in which the validation below is stricter then the spec requires:
-- - We don't allow the `aud` claim to contain any audiences beyond ourselves.
validationSettings :: OpenIDConnect -> JWT.JWTValidationSettings
validationSettings oidc =
  -- The Client MUST validate that the aud (audience) Claim contains its
  -- client_id value registered at the Issuer identified by the iss (issuer)
  -- Claim as an audience. The aud (audience) Claim MAY contain an array with
  -- more than one element. The ID Token MUST be rejected if the ID Token does
  -- not list the Client as a valid audience, or if it contains additional
  -- audiences not trusted by the Client.
  validateAudience oidc
    -- If the ID Token is encrypted, decrypt it using the keys and algorithms
    -- that the Client specified during Registration that the OP was to use to
    -- encrypt the ID Token. If encryption was negotiated with the OP at
    -- Registration time and the ID Token is not encrypted, the RP SHOULD
    -- reject it.
    & JWT.defaultJWTValidationSettings
    -- The current time MUST be before the time represented by the exp Claim.
    & Lens.set JWT.jwtValidationSettingsCheckIssuedAt True
    -- The Issuer Identifier for the OpenID Provider (which is typically
    -- obtained during Discovery) MUST exactly match the value of the iss
    -- (issuer) Claim.
    & Lens.set JWT.jwtValidationSettingsIssuerPredicate (validateIssuer oidc)
    & Lens.set JWT.jwtValidationSettingsAllowedSkew (oidcAllowedSkew oidc)

validateAudience :: OpenIDConnect -> JWT.StringOrURI -> Bool
validateAudience oidc audClaim =
  audienceFromJWT == Just correctClientId
  where
    correctClientId = oidcClientId oidc
    audienceFromJWT = fromStringOrURI audClaim

validateIssuer :: OpenIDConnect -> JWT.StringOrURI -> Bool
validateIssuer oidc issClaim =
  issuerFromJWT == Just correctIssuer
  where
    correctIssuer = issuer (oidcMetadata oidc)
    issuerFromJWT = fromStringOrURI issClaim

fromStringOrURI :: JWT.StringOrURI -> Maybe T.Text
fromStringOrURI stringOrURI =
   fmap toText (Lens.Extras.preview JWT.string stringOrURI)
   <|> fmap (T.pack . show) (Lens.Extras.preview JWT.uri stringOrURI)

-- A small helper class for compatibility with different versions of the `jose`
-- library. Pre-0.8.x `JWT.string` produces a `String`. Post-0.8.x it produces a
-- `Text`. This type class allows us to support both.
--
-- We can drop this once we no longer wish to support `jose` versions 0.7.x and
-- before.
class ToText a where
  toText :: a -> T.Text

instance ToText T.Text where
  toText = id

instance ToText [Char] where
  toText = T.pack

storeClaims :: JWT.ClaimsSet -> Request -> Request
storeClaims claims req =
  req { vault = Vault.insert idTokenKey claims (vault req) }

-- | Get the @IdToken@ for the current user.
--
-- If called on a @Request@ behind the middleware, should always return a
-- @Just@ value.
--
-- The token returned was validated when the request was processed by the
-- middleware.
--
-- @since 0.2.3.0
getIdToken :: Request -> Maybe JWT.ClaimsSet
getIdToken req = Vault.lookup idTokenKey (vault req)

idTokenKey :: Vault.Key JWT.ClaimsSet
idTokenKey = unsafePerformIO Vault.newKey
{-# NOINLINE idTokenKey #-}
