import os
import json
from pathlib import Path
from datetime import datetime

from openhands.core.logger import openhands_logger as logger


class UserOnboardingService:
    """新用户初始化服务 - 创建用户隔离的目录结构"""
    
    DEFAULT_CONFIG_DIR = "~/.openhands"
    USER_CONFIG_DIR = "~/.openhands/users/{user_id}"
    
    # 用户目录结构
    USER_SUBDIRS = [
        "workspace",      
        ".openhands",    
    ]
    
    # 默认配置文件
    DEFAULT_FILES = [
        "settings.json",
    ]
    
    async def create_user(self, user_id: str, email: str) -> dict:
        """创建新用户目录结构"""
        
        user_base = Path(os.path.expanduser(
            self.USER_CONFIG_DIR.format(user_id=user_id)
        ))
        
        logger.info(f"Creating user directories for user: {user_id}")
        
        # 1. 创建用户目录
        user_base.mkdir(parents=True, exist_ok=True)
        
        # 2. 创建子目录
        for subdir in self.USER_SUBDIRS:
            (user_base / subdir).mkdir(exist_ok=True)
        
        # 3. 直接创建默认配置（不使用全局配置，确保每个用户独立）
        for filename in self.DEFAULT_FILES:
            dst = user_base / ".openhands" / filename
            await self._create_default_config(dst, user_id, email)
        
        # 4. 记录用户元数据
        await self._save_user_metadata(user_id, email)
        
        logger.info(f"User {user_id} created successfully")
        
        return {
            "user_id": user_id,
            "email": email,
            "workspace_path": str(user_base / "workspace"),
            "config_path": str(user_base / ".openhands")
        }
    
    async def _copy_and_update_config(self, src: Path, dst: Path, user_id: str, email: str):
        """复制并更新配置文件"""
        try:
            import shutil
            shutil.copy2(src, dst)
            
            # 更新配置中的用户特定字段
            content = json.loads(dst.read_text())
            content['user_id'] = user_id
            content['email'] = email
            dst.write_text(json.dumps(content, indent=2))
        except Exception as e:
            logger.warning(f"Failed to copy config, creating default: {e}")
            await self._create_default_config(dst, user_id, email)
    
    async def _create_default_config(self, path: Path, user_id: str, email: str):
        """创建默认配置文件"""
        default_settings: dict = {
            "language": "zh",
            "agent": "CodeActAgent",
            "max_iterations": None,
            "security_analyzer": None,
            "confirmation_mode": None,
            "llm_model": os.environ.get("OPENHANDS_DEFAULT_LLM_MODEL", ""),
            "llm_api_key": os.environ.get("OPENHANDS_DEFAULT_LLM_API_KEY", ""),
            "llm_base_url": os.environ.get("OPENHANDS_DEFAULT_LLM_BASE_URL", ""),
            "user_version": None,
            "remote_runtime_resource_factor": None,
            "secrets_store": {"provider_tokens": {}},
            "enable_default_condenser": True,
            "enable_sound_notifications": False,
            "enable_proactive_conversation_starters": True,
            "enable_solvability_analysis": True,
            "user_consents_to_analytics": False,
            "sandbox_base_container_image": None,
            "sandbox_runtime_container_image": None,
            "mcp_config": None,
            "search_api_key": None,
            "sandbox_api_key": None,
            "max_budget_per_task": None,
            "condenser_max_size": 240,
            "email": email,
            "git_user_name": f"user_{user_id[:8]}",
            "git_user_email": email,
            "v1_enabled": True,
            "user_id": user_id,
        }
        
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(default_settings, indent=2))
        logger.info(f"Created default config at {path}")
    
    async def _save_user_metadata(self, user_id: str, email: str):
        """保存用户元数据"""
        metadata_path = Path(
            os.path.expanduser(
                self.USER_CONFIG_DIR.format(user_id=user_id)
            )
        ) / "metadata.json"
        
        metadata = {
            "user_id": user_id,
            "email": email,
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "status": "active",
        }
        
        metadata_path.write_text(json.dumps(metadata, indent=2))
    
    async def delete_user(self, user_id: str) -> bool:
        """删除用户及其所有数据"""
        import shutil
        
        user_base = Path(os.path.expanduser(
            self.USER_CONFIG_DIR.format(user_id=user_id)
        ))
        
        if user_base.exists():
            shutil.rmtree(user_base)
            logger.info(f"Deleted user data for: {user_id}")
            return True
        
        return False
    
    async def get_user_workspace_path(self, user_id: str) -> str:
        """获取用户工作空间路径"""
        return str(Path(os.path.expanduser(
            self.USER_CONFIG_DIR.format(user_id=user_id)
        )) / "workspace")
    
    async def get_user_config_path(self, user_id: str) -> str:
        """获取用户配置路径"""
        return str(Path(os.path.expanduser(
            self.USER_CONFIG_DIR.format(user_id=user_id)
        )) / ".openhands")
