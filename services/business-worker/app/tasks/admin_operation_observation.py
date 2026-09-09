"""Acknowledge a narrowly validated internal credential observation.

PUBLISHED means the Worker accepted this already-persisted security event. It
does not mean email delivery, password verification by this consumer, or success
of a later wallet command. This consumer has no business or network side effects.
"""
import re
from app.core.outbox import OutboxMessage


class AdminOperationObservationTask:
    def __call__(self,message):
        if (not isinstance(message,OutboxMessage)
                or message.topic!='identity.admin_operation'
                or message.event_type not in {'identity.admin_operation.changed','identity.admin_operation.verified'}
                or message.aggregate_type!='admin_operation_credential'
                or not isinstance(message.aggregate_id,str)
                or re.fullmatch(r'[A-Za-z0-9_.:-]{1,36}',message.aggregate_id) is None
                or not isinstance(message.payload,dict)
                or set(message.payload)!={'version','auth_mode'}
                or type(message.payload['version']) is not int
                or not 1<=message.payload['version']<=2147483647
                or message.payload['auth_mode']!='operation_password'
                or message.headers!={}):
            # Never include invalid payloads, identifiers or headers in errors.
            raise ValueError('ADMIN_OPERATION_EVENT_INVALID')
