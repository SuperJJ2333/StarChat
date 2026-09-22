"""ADR-0079 实施补充：群主转让协调恢复（崩溃/超时/重试的兜底推进）。"""
from app.modules.groups.registry import GroupRegistryService
from app.modules.groups.transfer_coordination import GroupTransferCoordinator


class GroupTransferRecoveryTask:
    def __init__(self, session_factory, *, matrix_gateway, enabled=False) -> None:
        self.enabled = enabled
        registry = GroupRegistryService(session_factory, matrix_gateway=matrix_gateway)
        self._coordinator = GroupTransferCoordinator(session_factory,
            registry=registry, matrix_gateway=matrix_gateway)

    def run_batch(self, *, limit: int = 20) -> dict:
        if not self.enabled:
            return {'scanned': 0, 'completed': 0, 'retried': 0, 'review': 0}
        return self._coordinator.recover_batch(limit=limit)
