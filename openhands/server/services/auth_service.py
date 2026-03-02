import os
import jwt
import uuid
import hashlib
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException, status
from pydantic import BaseModel

from openhands.core.logger import openhands_logger as logger


# JWT 配置
JWT_SECRET = os.environ.get("JWT_SECRET", "openhands-dev-secret-change-in-production")
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_HOURS = 24 * 7  # 7 天


class User(BaseModel):
    """用户模型"""
    user_id: str
    email: str
    username: str
    created_at: str


class TokenData(BaseModel):
    """Token 数据"""
    user_id: str
    email: str
    exp: Optional[int] = None


def generate_jwt(user_id: str, email: str) -> str:
    """生成 JWT Token"""
    payload = {
        "user_id": user_id,
        "email": email,
        "iat": datetime.utcnow(),
        "exp": datetime.utcnow() + timedelta(hours=JWT_EXPIRE_HOURS),
    }
    token = jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)
    return token


def verify_jwt(token: str) -> TokenData:
    """验证 JWT Token"""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
        return TokenData(
            user_id=payload["user_id"],
            email=payload["email"],
            exp=payload.get("exp"),
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token has expired",
        )
    except jwt.InvalidTokenError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token",
        )


def hash_password(password: str) -> str:
    """密码哈希"""
    return hashlib.sha256(password.encode()).hexdigest()


def verify_password(plain_password: str, hashed_password: str) -> bool:
    """验证密码"""
    return hash_password(plain_password) == hashed_password


class InMemoryUserStore:
    """内存用户存储 - 开发/测试用，生产环境应使用数据库"""
    
    def __init__(self):
        self._users = {}  # user_id -> user data
        self._email_index = {}  # email -> user_id
        self._username_index = {}  # username -> user_id
    
    async def create_user(self, email: str, username: str, password: str) -> User:
        """创建用户"""
        # 检查邮箱是否已存在
        if email in self._email_index:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Email already registered"
            )
        
        # 检查用户名是否已存在
        if username in self._username_index:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Username already taken"
            )
        
        user_id = str(uuid.uuid4())
        
        user_data = {
            "user_id": user_id,
            "email": email,
            "username": username,
            "password_hash": hash_password(password),
            "created_at": datetime.now().isoformat(),
            "updated_at": datetime.now().isoformat(),
            "is_active": True,
        }
        
        self._users[user_id] = user_data
        self._email_index[email] = user_id
        self._username_index[username] = user_id
        
        logger.info(f"Created user: {user_id} ({email})")
        
        return User(
            user_id=user_id,
            email=email,
            username=username,
            created_at=str(user_data["created_at"])
        )

    async def get_user(self, user_id: str) -> Optional[dict]:
        """获取用户"""
        return self._users.get(user_id)
    
    async def get_user_by_email(self, email: str) -> Optional[dict]:
        """通过邮箱获取用户"""
        user_id = self._email_index.get(email)
        if user_id:
            return self._users.get(user_id)
        return None
    
    async def authenticate(self, email: str, password: str) -> Optional[User]:
        """验证用户"""
        user_data = await self.get_user_by_email(email)
        
        if not user_data:
            return None
        
        if not verify_password(password, user_data["password_hash"]):
            return None
        
        if not user_data.get("is_active", True):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="User account is disabled"
            )
        
        return User(
            user_id=user_data["user_id"],
            email=user_data["email"],
            username=user_data["username"],
            created_at=user_data["created_at"]
        )
    
    async def update_user(self, user_id: str, updates: dict) -> Optional[dict]:
        """更新用户"""
        if user_id in self._users:
            self._users[user_id].update(updates)
            self._users[user_id]["updated_at"] = datetime.now().isoformat()
            return self._users[user_id]
        return None
    
    async def delete_user(self, user_id: str) -> bool:
        """删除用户"""
        if user_id in self._users:
            user_data = self._users[user_id]
            del self._email_index[user_data["email"]]
            del self._username_index[user_data["username"]]
            del self._users[user_id]
            logger.info(f"Deleted user: {user_id}")
            return True
        return False


# 全局用户存储实例
user_store = InMemoryUserStore()
