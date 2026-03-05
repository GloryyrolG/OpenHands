import os
from dataclasses import dataclass

from fastapi import Request, HTTPException, status
from pydantic import SecretStr

from openhands.integrations.provider import PROVIDER_TOKEN_TYPE
from openhands.server import shared
from openhands.server.settings import Settings
from openhands.server.services.auth_service import verify_jwt
from openhands.server.user_auth.user_auth import UserAuth
from openhands.storage.data_models.secrets import Secrets
from openhands.storage.secrets.secrets_store import SecretsStore
from openhands.storage.settings.settings_store import SettingsStore


@dataclass
class JWTUserAuth(UserAuth):
    """JWT-based multi-user authentication"""
    
    _request: Request
    _user_id: str | None = None
    _settings: Settings | None = None
    _settings_store: SettingsStore | None = None
    _secrets_store: SecretsStore | None = None
    _secrets: Secrets | None = None

    async def _get_user_id_from_token(self) -> str | None:
        """Extract user_id from JWT token in Authorization header"""
        auth_header = self._request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return None
        
        token = auth_header.replace("Bearer ", "")
        try:
            token_data = verify_jwt(token)
            return token_data.user_id
        except:
            return None

    async def get_user_id(self) -> str | None:
        if self._user_id is None:
            self._user_id = await self._get_user_id_from_token()
        return self._user_id

    async def get_user_email(self) -> str | None:
        auth_header = self._request.headers.get("Authorization")
        if not auth_header or not auth_header.startswith("Bearer "):
            return None
        
        token = auth_header.replace("Bearer ", "")
        try:
            token_data = verify_jwt(token)
            return token_data.email
        except:
            return None

    async def get_access_token(self) -> SecretStr | None:
        auth_header = self._request.headers.get("Authorization")
        if auth_header and auth_header.startswith("Bearer "):
            return SecretStr(auth_header.replace("Bearer ", ""))
        return None

    async def get_user_settings_store(self) -> SettingsStore:
        settings_store = self._settings_store
        if settings_store:
            return settings_store
        
        user_id = await self.get_user_id()
        if not user_id:
            # No JWT token, use global settings (backward compatibility)
            user_id = None
            
        settings_store = await shared.SettingsStoreImpl.get_instance(
            shared.config, user_id
        )
        if settings_store is None:
            raise ValueError('Failed to get settings store instance')
        self._settings_store = settings_store
        return settings_store

    async def get_user_settings(self) -> Settings | None:
        # Re-read every time, no caching
        settings_store = await self.get_user_settings_store()
        settings = await settings_store.load()

        # Merge config.toml settings with stored settings
        if settings:
            settings = settings.merge_with_config_settings()
            return settings

        # No settings file found — return defaults from env vars so the
        # frontend doesn't show "Settings not found" for new users
        default_model = os.environ.get("OPENHANDS_DEFAULT_LLM_MODEL", "")
        default_base = os.environ.get("OPENHANDS_DEFAULT_LLM_BASE_URL", "")
        default_key = os.environ.get("OPENHANDS_DEFAULT_LLM_API_KEY", "")
        if default_model:
            return Settings(
                llm_model=default_model,
                llm_base_url=default_base or None,
                llm_api_key=SecretStr(default_key) if default_key else None,
            )

        return None

    async def get_secrets_store(self) -> SecretsStore:
        secrets_store = self._secrets_store
        if secrets_store:
            return secrets_store
        
        user_id = await self.get_user_id()
        if not user_id:
            user_id = None
            
        secret_store = await shared.SecretsStoreImpl.get_instance(
            shared.config, user_id
        )
        if secret_store is None:
            raise ValueError('Failed to get secrets store instance')
        self._secrets_store = secret_store
        return secret_store

    async def get_secrets(self) -> Secrets | None:
        user_secrets = self._secrets
        if user_secrets:
            return user_secrets
        secrets_store = await self.get_secrets_store()
        user_secrets = await secrets_store.load()
        self._secrets = user_secrets
        return user_secrets

    async def get_provider_tokens(self) -> PROVIDER_TOKEN_TYPE | None:
        user_secrets = await self.get_secrets()
        if user_secrets is None:
            return None
        return user_secrets.provider_tokens

    async def get_mcp_api_key(self) -> str | None:
        return None

    @classmethod
    async def get_instance(cls, request: Request) -> UserAuth:
        return JWTUserAuth(_request=request)

    @classmethod
    async def get_for_user(cls, user_id: str) -> UserAuth:
        raise NotImplementedError("JWT auth doesn't support get_for_user")
