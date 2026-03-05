"""Add share_token to conversation_metadata table

Revision ID: 007
Revises: 006
Create Date: 2026-03-05 00:00:00.000000

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '007'
down_revision: Union[str, None] = '006'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Add share_token column to conversation_metadata table."""
    with op.batch_alter_table('conversation_metadata') as batch_op:
        batch_op.add_column(
            sa.Column('share_token', sa.String(), nullable=True)
        )
        batch_op.create_index(
            'ix_conversation_metadata_share_token',
            ['share_token'],
            unique=True,
        )


def downgrade() -> None:
    """Remove share_token column from conversation_metadata table."""
    with op.batch_alter_table('conversation_metadata') as batch_op:
        batch_op.drop_index('ix_conversation_metadata_share_token')
        batch_op.drop_column('share_token')
