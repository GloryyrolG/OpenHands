from __future__ import annotations

import json
import os
from dataclasses import dataclass

from openhands.core.config.openhands_config import OpenHandsConfig
from openhands.core.logger import openhands_logger as logger
from openhands.storage import get_file_store
from openhands.storage.data_models.settings import Settings
from openhands.storage.files import FileStore
from openhands.storage.settings.settings_store import SettingsStore
from openhands.utils.async_utils import call_sync_from_async


# 用户隔离的配置目录
def get_user_config_path(user_id: str | None, config: OpenHandsConfig) -> str:
    """获取用户隔离的配置路径"""
    if user_id:
        # 用户隔离目录: ~/.openhands/users/{user_id}/.openhands
        base_path = os.path.expanduser(config.file_store_path or "~/.openhands")
        return os.path.join(base_path, "users", user_id, ".openhands")
    else:
        # 全局配置（兼容旧模式）: ~/.openhands
        return os.path.expanduser(config.file_store_path or "~/.openhands")


@dataclass
class FileSettingsStore(SettingsStore):
    file_store: FileStore
    path: str = 'settings.json'
    user_id: str | None = None
    global_file_store: FileStore | None = None

    async def load(self) -> Settings | None:
        try:
            json_str = await call_sync_from_async(self.file_store.read, self.path)
            kwargs = json.loads(json_str)

            settings = Settings(**kwargs)

            # Turn on V1 in OpenHands
            # We can simplify / remove this as part of V0 removal
            settings.v1_enabled = True

            return settings
        except FileNotFoundError:
            if self.user_id and self.global_file_store:
                logger.warning(f"User settings not found for user {self.user_id}, falling back to global settings")
                try:
                    json_str = await call_sync_from_async(self.global_file_store.read, self.path)
                    kwargs = json.loads(json_str)
                    settings = Settings(**kwargs)
                    settings.v1_enabled = True
                    # Auto-save to user path so future loads are fast
                    await call_sync_from_async(self.file_store.write, self.path, json_str)
                    logger.info(f"Initialized settings for user {self.user_id} from global settings")
                    return settings
                except FileNotFoundError:
                    logger.warning(f"Global settings not found either")
                    return None
            elif self.user_id:
                logger.warning(f"User settings not found for user: {self.user_id}")
            return None
        except json.JSONDecodeError as e:
            logger.error(f"Failed to parse settings: {e}")
            return None

    async def store(self, settings: Settings) -> None:
        # 注意：user_id 不需要保存在 Settings 中，因为已经通过目录路径隔离了
        json_str = settings.model_dump_json(context={'expose_secrets': True})
        await call_sync_from_async(self.file_store.write, self.path, json_str)

    @classmethod
    async def get_instance(
        cls, config: OpenHandsConfig, user_id: str | None
    ) -> FileSettingsStore:
        # 获取用户隔离的文件存储路径
        user_config_path = get_user_config_path(user_id, config)

        logger.info(f"Creating FileSettingsStore for user_id={user_id}, path={user_config_path}")

        file_store = get_file_store(
            file_store_type=config.file_store,
            file_store_path=user_config_path,
            file_store_web_hook_url=config.file_store_web_hook_url,
            file_store_web_hook_headers=config.file_store_web_hook_headers,
            file_store_web_hook_batch=config.file_store_web_hook_batch,
        )

        # 确保目录存在
        import os
        os.makedirs(user_config_path, exist_ok=True)

        global_file_store = None
        if user_id:
            # Create a global file store for fallback when user settings don't exist yet
            global_config_path = get_user_config_path(None, config)
            global_file_store = get_file_store(
                file_store_type=config.file_store,
                file_store_path=global_config_path,
                file_store_web_hook_url=config.file_store_web_hook_url,
                file_store_web_hook_headers=config.file_store_web_hook_headers,
                file_store_web_hook_batch=config.file_store_web_hook_batch,
            )

        return FileSettingsStore(file_store=file_store, user_id=user_id, global_file_store=global_file_store)
