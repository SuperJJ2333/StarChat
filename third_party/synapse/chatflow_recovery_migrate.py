"""Explicit expand-only migration; never changes Synapse schema_version/deltas."""
import hashlib
from pathlib import Path

LOCK_ID = 7395186231001


def migrate(connection):
    sql = (Path(__file__).parent / 'recovery_migrations/001.sql').read_text(encoding='utf-8')
    digest = hashlib.sha256(sql.encode()).hexdigest()
    with connection.transaction():
        with connection.cursor() as cursor:
            cursor.execute('SELECT pg_advisory_xact_lock(%s)', (LOCK_ID,))
            cursor.execute('CREATE TABLE IF NOT EXISTS chatflow_recovery_migrations '
                           '(revision INTEGER PRIMARY KEY, sha256 TEXT NOT NULL)')
            cursor.execute('SELECT revision, sha256 FROM chatflow_recovery_migrations ORDER BY revision')
            found = cursor.fetchall()
            if found and found != [(1, digest)]:
                raise RuntimeError('Recovery migration mismatch')
            if not found:
                cursor.execute(sql)
                cursor.execute('INSERT INTO chatflow_recovery_migrations VALUES (1, %s)', (digest,))


if __name__ == '__main__':
    # libpq service file/password file permissions are the operator's responsibility.
    # No DSN or password argument/output. PostgreSQL environment or service config.
    import psycopg
    with psycopg.connect('') as connection:
        migrate(connection)
    print('Recovery migration 1 verified')
