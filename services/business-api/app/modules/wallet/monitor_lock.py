"""Nonblocking whole-scan locks, independent from financial write transactions."""
from contextlib import contextmanager
import errno
import os
from pathlib import Path
from threading import Lock
from weakref import WeakKeyDictionary


_memory_locks = WeakKeyDictionary()
_memory_guard = Lock()
_PG_NAMESPACE = 1464025933


@contextmanager
def _postgres_lock(engine):
    # A dedicated pool inherits the configured connection creator/authentication
    # but does not occupy the source pool while independent service calls run.
    # In particular, a source pool of size one must still be able to read/write.
    pool = engine.pool.recreate()
    connection = None
    acquired = False
    try:
        connection = pool.connect()
        with connection.cursor() as cursor:
            cursor.execute('SELECT pg_try_advisory_lock(%s, %s)', (_PG_NAMESPACE, 1))
            acquired = bool(cursor.fetchone()[0])
        connection.commit()
        yield acquired
    finally:
        try:
            if connection is not None and acquired:
                connection.rollback()
                with connection.cursor() as cursor:
                    cursor.execute('SELECT pg_advisory_unlock(%s, %s)', (_PG_NAMESPACE, 1))
                connection.commit()
        finally:
            if connection is not None:
                # Always discard this dedicated session. If unlock/commit failed,
                # it must never return a session-level lock to a reusable pool.
                connection.invalidate()
                connection.close()
            pool.dispose()


@contextmanager
def _file_lock(database):
    path = Path(os.path.normcase(str(Path(database).resolve())))
    # Never unlink this file: contenders must all lock the same stable inode.
    with Path(str(path) + '.wallet-monitor.lock').open('a+b') as stream:
        if os.name == 'nt':
            import msvcrt
            if stream.seek(0, os.SEEK_END) == 0:
                stream.write(b'\0')
                stream.flush()
            stream.seek(0)
            try:
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as exc:
                if exc.errno not in {errno.EACCES, errno.EAGAIN, errno.EDEADLK}:
                    raise
                yield False
                return
            try:
                yield True
            finally:
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            try:
                yield True
            finally:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


@contextmanager
def monitor_scan_lock(factory):
    # get_bind() does not open a source connection or execute a database read.
    with factory() as session:
        bind = session.get_bind()
        engine = getattr(bind, 'engine', bind)
    if engine.dialect.name == 'postgresql':
        with _postgres_lock(engine) as acquired:
            yield acquired
    elif engine.dialect.name == 'sqlite':
        database = engine.url.database
        if database and database != ':memory:' and engine.url.query.get('mode') != 'memory':
            with _file_lock(database) as acquired:
                yield acquired
        else:
            with _memory_guard:
                lock = _memory_locks.setdefault(engine, Lock())
            acquired = lock.acquire(blocking=False)
            try:
                yield acquired
            finally:
                if acquired:
                    lock.release()
    else:
        raise ValueError('unsupported monitor database')
