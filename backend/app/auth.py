"""Password auth with JWT bearer tokens; every request resolves to one user in one organization.

Manage users: python -m app.auth add <email> <manager|scout> --name "Name" [--password ...]
"""

import argparse
import getpass
import sys
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import settings
from app.db import pool

_hasher = PasswordHasher()
_bearer = HTTPBearer(auto_error=False)
# Verified against when the email is unknown, so response time doesn't reveal which emails exist.
_DUMMY_HASH = _hasher.hash("not-a-real-password")


@dataclass(frozen=True)
class User:
    id: str
    email: str
    display_name: str
    org_id: str
    role: str

    @property
    def is_manager(self) -> bool:
        return self.role == "manager"


_USER_SQL = """
    SELECT u.id::text, u.email, u.display_name, u.password_hash, m.org_id::text, m.role
    FROM users u JOIN memberships m ON m.user_id = u.id
    WHERE {where}
    ORDER BY m.org_id LIMIT 1
"""


def authenticate(email: str, password: str) -> User | None:
    with pool.connection() as conn:
        row = conn.execute(_USER_SQL.format(where="u.email = %s"), (email.strip().lower(),)).fetchone()
    try:
        _hasher.verify(row["password_hash"] if row else _DUMMY_HASH, password)
    except VerifyMismatchError:
        return None
    if row is None:
        return None
    return User(row["id"], row["email"], row["display_name"], row["org_id"], row["role"])


def issue_token(user: User) -> str:
    now = datetime.now(UTC)
    # Long-lived on purpose: scouts may be offline in the field for days.
    claims = {"sub": user.id, "iat": now, "exp": now + timedelta(days=settings.token_ttl_days)}
    return jwt.encode(claims, settings.jwt_secret, algorithm="HS256")


def current_user(creds: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)]) -> User:
    if creds is None:
        raise HTTPException(401, "not authenticated", headers={"WWW-Authenticate": "Bearer"})
    try:
        user_id = jwt.decode(creds.credentials, settings.jwt_secret, algorithms=["HS256"])["sub"]
    except jwt.PyJWTError:
        raise HTTPException(401, "invalid or expired token", headers={"WWW-Authenticate": "Bearer"})
    with pool.connection() as conn:
        row = conn.execute(_USER_SQL.format(where="u.id = %s"), (user_id,)).fetchone()
    if row is None:
        raise HTTPException(401, "user no longer exists")
    return User(row["id"], row["email"], row["display_name"], row["org_id"], row["role"])


def manager(user: Annotated[User, Depends(current_user)]) -> User:
    if not user.is_manager:
        raise HTTPException(403, "managers only")
    return user


CurrentUser = Annotated[User, Depends(current_user)]
Manager = Annotated[User, Depends(manager)]


def _add_user(args: argparse.Namespace) -> None:
    password = args.password or getpass.getpass("Password: ")
    if len(password) < 8:
        sys.exit("password must be at least 8 characters")
    with pool.connection() as conn:
        user_id = conn.execute(
            """
            INSERT INTO users (email, display_name, password_hash) VALUES (%s, %s, %s)
            ON CONFLICT (email) DO UPDATE SET display_name = EXCLUDED.display_name,
                password_hash = EXCLUDED.password_hash
            RETURNING id
            """,
            (args.email.strip().lower(), args.name or args.email.split("@")[0], _hasher.hash(password)),
        ).fetchone()["id"]
        conn.execute(
            """
            INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, %s)
            ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role
            """,
            (user_id, args.org or settings.default_org_id, args.role),
        )
    print(f"{args.role} {args.email} ready")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(prog="python -m app.auth")
    sub = parser.add_subparsers(required=True)
    add = sub.add_parser("add", help="create a user or reset their password/role")
    add.add_argument("email")
    add.add_argument("role", choices=["manager", "scout"])
    add.add_argument("--name")
    add.add_argument("--password", help="omit to be prompted")
    add.add_argument("--org", help="organization id (default: the seeded default org)")
    add.set_defaults(func=_add_user)
    args = parser.parse_args()
    pool.open()
    args.func(args)
