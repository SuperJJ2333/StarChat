from decimal import Decimal
from fastapi import Depends, FastAPI
from app.api.admin_session_boundary import create_admin_session_boundary
from app.integrations.tron import diagnostics as wallet_diagnostics

from app.api.health import create_health_router
from app.api.client_diagnostics import create_client_diagnostics_router
from app.api.performance_diagnostics import create_performance_diagnostics_router
from app.api.identity import create_identity_router
from app.api.support import create_support_router
from app.api.ledger import create_ledger_router
from app.api.redpacket import create_redpacket_router
from app.api.app_update import create_app_update_router
from app.api.payment_pin import create_payment_pin_router
from app.api.transfer import create_transfer_router
from app.api.wallet import create_wallet_router
from app.api.wallet_mfa import create_wallet_mfa_router
from app.api.wallet_access import create_wallet_access_router
from app.modules.wallet.runtime import create_manual_wallet_runtime
from app.api.friendship import create_friendship_router
from app.api.fx import create_fx_router
from app.api.recharge import create_recharge_router
from app.api.support_order_security import create_support_order_security_router
from app.api.support_payout import create_support_payout_router
from app.modules.recharge.service import RechargeService
from app.modules.ledger.service import LedgerService
from app.api.moments import create_moments_router
from app.api.media import create_media_router
from app.api.media_platform import create_media_platform_router
from app.api.profile import create_profile_router
from app.api.groups import create_group_router
from app.api.admin import create_admin_router
from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.errors import ErrorEnvelope, install_error_handlers
from app.core.tracing import install_trace_middleware
from app.core.rate_limits import NoopRateLimiter, RedisRateLimiter
from app.integrations.matrix_admin import SynapseMatrixAdminGateway
from app.integrations.private_storage import LocalPrivateObjectStorage


def create_app(
    settings: Settings,
    session_factory=None,
    rate_limiter=None,
    matrix_gateway=None,
    avatar_storage=None,
) -> FastAPI:
    wallet_diagnostics.configure('business-api')
    wallet_diagnostics.emit('INFO', 'service_starting', component='api')
    app = FastAPI(
        title=settings.app_name,
        version="0.1.0",
        responses={
            400: {"model": ErrorEnvelope, "description": "Application error"},
            422: {"model": ErrorEnvelope, "description": "Validation error"},
            500: {"model": ErrorEnvelope, "description": "Internal error"},
        },
    )
    if session_factory is None:
        engine = create_engine(settings)
        session_factory = create_session_factory(engine)
        app.state.engine = engine
    app.state.session_factory = session_factory
    app.router.dependencies.append(Depends(create_admin_session_boundary(settings, session_factory)))
    if rate_limiter is None:
        rate_limiter = (
            NoopRateLimiter()
            if settings.environment == "test"
            else RedisRateLimiter.from_url(settings.redis_url)
        )
    app.state.rate_limiter = rate_limiter
    app.include_router(create_client_diagnostics_router(settings, session_factory, rate_limiter), prefix="/api/v1")
    manual_wallet_runtime = create_manual_wallet_runtime(settings, session_factory, rate_limiter)
    app.state.manual_wallet_runtime = manual_wallet_runtime
    if manual_wallet_runtime is not None:
        manual_wallet_runtime.payouts.support_orders_enabled = True
        app.router.on_shutdown.append(manual_wallet_runtime.close)
    if matrix_gateway is None:
        matrix_gateway = SynapseMatrixAdminGateway(
            homeserver_url=settings.matrix_homeserver_url,
            server_name=settings.matrix_server_name,
            admin_access_token=settings.synapse_admin_access_token or "",
        )
    if avatar_storage is None:
        avatar_storage = LocalPrivateObjectStorage(
            root=settings.avatar_storage_root,
            signing_secret=(
                settings.avatar_url_signing_secret
                or "development-avatar-signing-secret"
            ),
            public_base_url=settings.avatar_public_base_url,
        )
    install_trace_middleware(app)
    install_error_handlers(app)
    app.include_router(create_performance_diagnostics_router(settings), prefix="/api/v1")
    app.include_router(
        create_health_router(settings, session_factory=session_factory),
        prefix="/api/v1",
    )
    app.include_router(
        create_profile_router(settings, session_factory, storage=avatar_storage),
        prefix="/api/v1",
    )
    app.include_router(
        create_identity_router(
            settings,
            session_factory,
            rate_limiter,
            matrix_gateway=matrix_gateway,
        ),
        prefix="/api/v1",
    )
    app.include_router(create_support_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_ledger_router(settings, session_factory, avatar_storage=avatar_storage), prefix="/api/v1")
    app.include_router(create_redpacket_router(settings, session_factory, avatar_storage=avatar_storage, matrix_gateway=matrix_gateway), prefix="/api/v1")
    app.include_router(create_app_update_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_transfer_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_payment_pin_router(settings, session_factory, rate_limiter), prefix="/api/v1")
    app.include_router(create_wallet_router(settings, session_factory, manual_runtime=manual_wallet_runtime), prefix="/api/v1")
    app.include_router(create_wallet_mfa_router(settings, session_factory, rate_limiter), prefix="/api/v1")
    app.include_router(create_wallet_access_router(settings, session_factory), prefix="/api/v1")
    app.include_router(
        create_friendship_router(
            settings,
            session_factory,
            avatar_storage=avatar_storage,
            rate_limiter=rate_limiter,
            matrix_gateway=matrix_gateway,
        ),
        prefix="/api/v1",
    )
    app.include_router(create_moments_router(settings, session_factory, avatar_storage=avatar_storage), prefix="/api/v1")
    app.include_router(
        create_media_router(
            settings,
            session_factory,
            rate_limiter,
            storage=avatar_storage,
        ),
        prefix="/api/v1",
    )
    app.include_router(create_group_router(settings, session_factory, matrix_gateway=matrix_gateway), prefix="/api/v1")
    app.include_router(create_fx_router(settings, session_factory), prefix="/api/v1")
    # ADR-0077：人工充值（客服结算）；汇率提供者与 FX 展示共用同一持久缓存。
    from app.modules.fx.service import FxService as _FxService

    _fx = _FxService(session_factory,
        api_id=settings.fx_api_id.get_secret_value() if settings.fx_api_id else None,
        api_key=settings.fx_api_key.get_secret_value() if settings.fx_api_key else None,
        api_url=settings.fx_api_url, ttl_seconds=settings.fx_cache_ttl_seconds)

    def _recharge_rate_provider():
        snapshot = _fx.get_rate_snapshot(actor_id='recharge-reference')
        return snapshot['rate'], bool(snapshot.get('stale'))

    _recharge_ledger = LedgerService(session_factory)
    from app.modules.identity.profile import ProfileService

    _recharge_ledger.reserve_policy = getattr(settings, "wallet_reserve_policy", "full_backing")
    _recharge = RechargeService(session_factory, ledger=_recharge_ledger, rate_provider=_recharge_rate_provider,
        wallet_receipts=manual_wallet_runtime.receipts if manual_wallet_runtime else None,
        official_config=manual_wallet_runtime.receipts.official_config if manual_wallet_runtime else None,
        profile_reader=ProfileService(session_factory, storage=avatar_storage))
    _recharge.adjustment_admin_threshold = Decimal(str(getattr(settings, "adjustment_admin_threshold", "10000")))
    _recharge.settlement_enabled = bool(manual_wallet_runtime and manual_wallet_runtime.deposits_enabled)
    app.state.recharge_service = _recharge
    app.include_router(create_recharge_router(settings, session_factory, recharge_service=_recharge), prefix="/api/v1")
    app.include_router(create_support_order_security_router(settings, session_factory), prefix="/api/v1")
    app.include_router(create_support_payout_router(settings, session_factory, runtime=manual_wallet_runtime), prefix="/api/v1")
    app.include_router(
        create_media_platform_router(
            settings,
            session_factory,
            service=_build_media_platform_service(settings, session_factory, avatar_storage),
            bridge=_build_moments_bridge(settings, session_factory, avatar_storage),
        ),
        prefix="/api/v1",
    )
    app.include_router(create_admin_router(settings, session_factory, manual_runtime=manual_wallet_runtime), prefix="/api/v1")
    return app


def _build_moments_bridge(settings: Settings, session_factory, storage):
    """The Moments bridge reuses the platform service and the existing Moments validators."""

    from app.modules.media.moments_bridge import MomentsMediaBridge

    return MomentsMediaBridge(
        service=_build_media_platform_service(settings, session_factory, storage),
        session_factory=session_factory,
        storage=storage,
    )


def _build_media_platform_service(settings: Settings, session_factory, storage):
    """Assemble the Media Platform (Phase 4).

    The platform writes into the same private object directory the business API already
    owns; it is a new key namespace, not a second storage system and not a second cache.
    """

    from app.modules.media.audience import AudienceRegistry, MomentsAudienceVerifier
    from app.modules.media.authorization import GrantAuthorizer, OwnerOnlyAuthorizer
    from app.modules.media.gateway import (
        BusinessMediaGateway,
        MatrixMediaGateway,
        MediaGatewayRegistry,
    )
    from app.modules.media.grants import MediaGrantService
    from app.modules.media.lifecycle import MediaGarbageCollector
    from app.modules.media.policy import MediaPlatformPolicy, MediaTtlPolicy
    from app.modules.media.reconcile import MediaReconciler
    from app.modules.media.references import MediaReferenceService
    from app.modules.media.repository import MediaRepository
    from app.modules.media.service import MediaPlatformService
    from app.modules.media.signed_urls import MediaSignedUrlCodec
    from app.modules.media.storage import LocalBlobBackend
    from app.modules.media.upload_engine import MediaUploadEngine
    from app.modules.media.variants import VariantResolver

    policy = MediaPlatformPolicy(
        ttl=MediaTtlPolicy(
            private_seconds=settings.media_ttl_private_seconds,
            audience_seconds=settings.media_ttl_audience_seconds,
            public_seconds=settings.media_ttl_public_seconds,
        ),
        orphan_grace_seconds=settings.media_orphan_grace_seconds,
        e2ee_retention_floor_seconds=settings.media_e2ee_retention_floor_seconds,
    )
    backend = LocalBlobBackend(root=settings.avatar_storage_root)
    repository = MediaRepository(
        session_factory, backend=backend, dedup_policy=policy.dedup
    )
    resolver = VariantResolver(repository)
    grants = MediaGrantService(session_factory)
    # Phase 4.4 decision function. Falls back to the narrow owner-only rule only when the
    # grant service is not wired, which never happens in create_app but keeps the type
    # honest for tests that build the gateway by hand.
    authorizer = (
        GrantAuthorizer(grants=grants, ttl_policy=policy.ttl)
        if grants is not None
        else OwnerOnlyAuthorizer(ttl_policy=policy.ttl)
    )
    registry = MediaGatewayRegistry(
        matrix=MatrixMediaGateway(),
        business=BusinessMediaGateway(
            repository=repository,
            resolver=resolver,
            authorizer=authorizer,
            policy=policy,
        ),
    )
    return MediaPlatformService(
        repository=repository,
        resolver=resolver,
        registry=registry,
        upload_engine=MediaUploadEngine(session_factory, policy=policy),
        policy=policy,
        authorizer=authorizer,
        references=MediaReferenceService(session_factory),
        collector=MediaGarbageCollector(session_factory, backend=backend, policy=policy),
        grants=grants,
        audience=AudienceRegistry(verifiers=(MomentsAudienceVerifier(session_factory),)),
        reconciler=MediaReconciler(
            session_factory,
            backend=backend,
            # Reconcile scans the private object directory itself, so it is told where that
            # directory is instead of introspecting the backend it was handed.
            root=settings.avatar_storage_root,
        ),
        codec=MediaSignedUrlCodec(
            # Prefer a dedicated media secret; fall back to the avatar signing secret so an
            # existing deployment works without a new mandatory secret. Rotating either
            # invalidates outstanding media URLs, which is the intended failure mode.
            secret=settings.media_url_signing_secret
            or settings.avatar_url_signing_secret,
        ),
    )


def create_default_app() -> FastAPI:
    return create_app(Settings())
