"""Read-only TRON observation integrations."""

from .reader import TronReader, TronReadError, validate_tron_address

__all__ = ['TronReader', 'TronReadError', 'validate_tron_address']
