from datetime import datetime, timedelta, timezone
from io import BytesIO
from uuid import uuid4

import pytest
from httpx import ASGITransport, AsyncClient
from PIL import Image
from test_moments_api import auth, ctx
from test_moment_video_media import VIDEO

from app.main import create_app
from app.core.errors import AppError
from app.integrations.private_storage import LocalPrivateObjectStorage
from app.modules.moments.media import MomentMediaService, MomentMediaUpload
from app.modules.moments.models import Moment, MomentsPreference
from app.modules.friendship.models import UserBlock


def image_bytes(fmt="PNG", size=(120, 80), *, animated=False):
    out = BytesIO()
    image = Image.new("RGB", size, "blue")
    if animated:
        image.save(out, fmt, save_all=True, append_images=[Image.new("RGB", size, "red")], duration=50)
    else:
        image.save(out, fmt)
    return out.getvalue()


@pytest.fixture
def poster_ctx(ctx, tmp_path):
    original, settings = ctx
    storage = LocalPrivateObjectStorage(root=str(tmp_path), signing_secret="x" * 32, public_base_url="http://test")
    return create_app(settings, session_factory=original.state.session_factory, avatar_storage=storage), settings, storage


async def upload(client, settings, *, owner="u1", purpose="poster", content=None, mime="image/png", key=None):
    content = image_bytes() if content is None else content
    headers = {**auth(settings, owner), "Idempotency-Key": key or str(uuid4())}
    path = "video-posters" if purpose == "poster" else "media"
    begun = await client.post(f"/api/v1/moments/{path}/uploads", headers=headers,
        json={"file_name": "synthetic.png", "mime_type": mime, "byte_size": len(content)})
    assert begun.status_code == 201, begun.text
    row = begun.json()
    assert (await client.put(row["upload_url"], headers={**headers, "Content-Type": mime}, content=content)).status_code == 204
    complete = await client.post(f"/api/v1/moments/media/uploads/{row['id']}/complete", headers=headers)
    assert complete.status_code == 200, complete.text
    return complete.json()


@pytest.mark.asyncio
async def test_poster_publish_aligned_capability_and_revocation(poster_ctx):
    app, settings, storage = poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        poster = await upload(c, settings)
        assert (await c.get(poster["media_url"])).content == image_bytes()
        video = await upload(c, settings, purpose="video", content=VIDEO, mime="video/mp4")
        payload = {"visibility": "FRIENDS", "video_urls": [video["media_url"], video["media_url"]], "video_poster_media_ids": [poster["id"], None]}
        headers = {**auth(settings, "u1"), "Idempotency-Key": "poster-publish"}
        response = await c.post("/api/v1/moments", headers=headers, json=payload)
        assert response.status_code == 201, response.text
        dto = response.json()
        assert len(dto["video_urls"]) == len(dto["video_poster_urls"]) == len(dto["video_poster_cache_keys"]) == 2
        assert dto["video_poster_urls"][1] is None
        assert dto["video_poster_cache_keys"][1] is None
        viewer = (await c.get(f"/api/v1/moments/{dto['id']}", headers=auth(settings, "u2"))).json()
        assert viewer["video_poster_cache_keys"] == dto["video_poster_cache_keys"]
        fetched = await c.get(viewer["video_poster_urls"][0])
        assert fetched.content == image_bytes()
        assert fetched.headers["content-type"] == "image/png"
        assert fetched.headers["cache-control"] == "private, no-store"
        with app.state.session_factory() as s:
            stored = s.get(Moment, dto["id"])
            assert stored.video_poster_keys == [f"moments/video-posters/u1/{poster['id']}.png", None]
        replay = await c.post("/api/v1/moments", headers=headers, json=payload)
        assert replay.status_code == 201 and replay.json()["id"] == dto["id"]
        collision = await c.post("/api/v1/moments", headers=headers, json={**payload, "video_poster_media_ids": [None, None]})
        assert collision.status_code == 409
        await c.patch(f"/api/v1/moments/{dto['id']}/visibility", headers=auth(settings, "u1"), json={"visibility": "SELF"})
        assert (await c.get(viewer["video_poster_urls"][0])).status_code == 404
        assert (await c.get(poster["media_url"])).status_code == 200


@pytest.mark.asyncio
@pytest.mark.parametrize("change", ["block", "delete", "history"])
async def test_poster_old_signed_url_rechecks_live_visibility(poster_ctx, change):
    app, settings, storage = poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        poster = await upload(c, settings)
        video = await upload(c, settings, purpose="video", content=VIDEO, mime="video/mp4")
        posted = await c.post("/api/v1/moments", headers={**auth(settings, "u1"), "Idempotency-Key": "post"}, json={"visibility": "FRIENDS", "video_urls": [video["media_url"]], "video_poster_media_ids": [poster["id"]]})
        assert posted.status_code == 201
        dto = (await c.get(f"/api/v1/moments/{posted.json()['id']}", headers=auth(settings,"u2"))).json()
        url = dto["video_poster_urls"][0]
        with app.state.session_factory.begin() as s:
            moment = s.get(Moment, dto["id"])
            if change == "delete": moment.deleted_at = datetime.now(timezone.utc)
            elif change == "history":
                moment.created_at = datetime.now(timezone.utc) - timedelta(days=10)
                s.add(MomentsPreference(user_id="u1", history_range="THREE_DAYS", personalized_recommendations=True, updated_at=datetime.now(timezone.utc)))
            else: s.add(UserBlock(id="synthetic-block", blocker_id="u1", blocked_id="u2", idempotency_key="block", created_at=datetime.now(timezone.utc)))
        assert (await c.get(url)).status_code == 404


@pytest.mark.asyncio
async def test_old_video_without_poster_remains_compatible(poster_ctx):
    app, settings, _ = poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        video = await upload(c, settings, purpose="video", content=VIDEO, mime="video/mp4")
        response = await c.post("/api/v1/moments", headers={**auth(settings, "u1"), "Idempotency-Key":"legacy"}, json={"visibility":"PUBLIC", "video_urls":[video["media_url"]]})
        assert response.status_code == 201
        dto = response.json()
        assert dto["video_poster_urls"] == [None]
        assert dto["video_poster_cache_keys"] == [None]
        assert (await c.get(dto["video_urls"][0])).content == VIDEO


@pytest.mark.parametrize("mime,size", [("image/gif",100), ("video/mp4",100), ("image/png",512*1024+1)])
def test_poster_begin_rejects_non_static_types_and_oversize(ctx, mime, size):
    app, _ = ctx
    with pytest.raises(AppError) as error:
        MomentMediaService(app.state.session_factory).begin("u1","synthetic",mime,size,"begin",purpose="MOMENT_VIDEO_POSTER")
    assert error.value.status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("content,mime", [(b"fakepng","image/png"),(image_bytes("JPEG"),"image/png"),(image_bytes(size=(481,1)),"image/png"),(image_bytes(animated=True),"image/png"),(image_bytes("WEBP",animated=True),"image/webp")], ids=["fake", "mime-mismatch", "oversized-edge", "apng", "animated-webp"])
async def test_poster_put_validates_actual_static_image(poster_ctx, content, mime):
    app, settings, storage = poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        headers={**auth(settings,"u1"),"Idempotency-Key":"invalid"}
        begun=await c.post("/api/v1/moments/video-posters/uploads",headers=headers,json={"file_name":"synthetic.png","mime_type":mime,"byte_size":len(content)})
        assert begun.status_code==201
        result=await c.put(begun.json()["upload_url"],headers={**headers,"Content-Type":mime},content=content)
        assert result.status_code==422
        with app.state.session_factory() as s:
            row=s.get(MomentMediaUpload,begun.json()["id"])
            assert row.status=="PENDING"
            assert not storage._path(row.object_key).exists()


@pytest.mark.asyncio
async def test_poster_references_require_completed_owner_and_purpose(poster_ctx):
    app,settings,_=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        video=await upload(c,settings,purpose="video",content=VIDEO,mime="video/mp4")
        foreign=await upload(c,settings,owner="u2")
        for posters in ([foreign["id"]],[video["id"]],[str(uuid4())],[None,None],["not-uuid"]):
            response=await c.post("/api/v1/moments",headers={**auth(settings,"u1"),"Idempotency-Key":str(uuid4())},json={"visibility":"PUBLIC","video_urls":[video["media_url"]],"video_poster_media_ids":posters})
            assert response.status_code==422
        draft={"video_urls":[video["media_url"]],"video_poster_media_ids":[foreign["id"]]}
        assert (await c.put("/api/v1/moments/draft",headers=auth(settings,"u1"),json={"payload":draft})).status_code==422


@pytest.mark.asyncio
@pytest.mark.parametrize("fmt,mime", [("JPEG","image/jpeg"),("PNG","image/png"),("WEBP","image/webp")])
async def test_valid_static_poster_and_boundary_dimensions(poster_ctx, fmt, mime):
    app,settings,_=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        content=image_bytes(fmt,size=(480,480))
        row=await upload(c,settings,content=content,mime=mime)
        assert (await c.get(row["media_url"])).content==content


@pytest.mark.asyncio
async def test_completed_validation_does_not_trust_stored_uploaded_status(poster_ctx):
    app,settings,storage=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        headers={**auth(settings,"u1"),"Idempotency-Key":"corrupt"}
        response=await c.post("/api/v1/moments/video-posters/uploads",headers=headers,json={"file_name":"synthetic.png","mime_type":"image/png","byte_size":3})
        assert response.status_code==201
        upload_id=response.json()["id"]
        with app.state.session_factory.begin() as s:
            row=s.get(MomentMediaUpload,upload_id)
            row.status="UPLOADED"
            storage.put(row.object_key,b"bad")
        complete=await c.post(f"/api/v1/moments/media/uploads/{upload_id}/complete",headers=headers)
        assert complete.status_code==422
        with app.state.session_factory() as s:
            assert s.get(MomentMediaUpload,upload_id).status=="UPLOADED"


@pytest.mark.asyncio
async def test_draft_poster_validated_and_saved_snapshot_can_compare_clear(poster_ctx):
    app,settings,_=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        poster=await upload(c,settings)
        video=await upload(c,settings,purpose="video",content=VIDEO,mime="video/mp4")
        payload={"text":"synthetic","video_urls":[video["media_url"]],"video_poster_media_ids":[poster["id"]]}
        headers=auth(settings,"u1")
        saved=await c.put("/api/v1/moments/draft",headers=headers,json={"payload":payload})
        assert saved.status_code==200
        expected=saved.json()
        assert expected["video_poster_media_ids"]==[poster["id"]]
        assert expected["video_urls"][0].startswith("media://")
        draft=(await c.get("/api/v1/moments/draft",headers=headers)).json()
        assert draft["video_poster_media_ids"]==expected["video_poster_media_ids"]
        assert draft["video_cache_keys"]==[video["media_cache_key"]]
        assert (await c.get(draft["video_urls"][0])).content==VIDEO
        # Signed read capabilities may renew, but changed metadata stays stale.
        mismatch=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":{**draft,"text":"newer"}})
        assert mismatch.json()=={"cleared":False}
        clear=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":draft})
        assert clear.json()=={"cleared":True}


@pytest.mark.asyncio
async def test_poster_token_cannot_rebind_upload_to_another_owner(poster_ctx):
    import json
    app,settings,storage=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        poster=await upload(c,settings)
        with app.state.session_factory() as s:
            key=s.get(MomentMediaUpload,poster["id"]).object_key
        forged_owner=storage.moment_read_url(json.dumps({"domain":"moment-upload-v1","key":key,"upload":poster["id"],"viewer":"u2"}))
        assert (await c.get(forged_owner)).status_code==404
        put=await c.put(f"/api/v1/moments/media/uploads/{poster['id']}/content",headers={**auth(settings,"u2"),"Content-Type":"image/png"},content=image_bytes())
        assert put.status_code==404
        comment_moment=await c.post("/api/v1/moments",headers={**auth(settings,"u1"),"Idempotency-Key":"comment-moment"},json={"visibility":"PUBLIC"})
        comment=await c.post(f"/api/v1/moments/{comment_moment.json()['id']}/comments",headers={**auth(settings,"u1"),"Idempotency-Key":"comment-poster"},json={"image_upload_ids":[poster["id"]]})
        assert comment.status_code==422


@pytest.mark.asyncio
async def test_poster_inbound_stream_stops_at_limit_without_reading_rest():
    from app.api.moments import read_moment_upload_content
    yielded=[]
    class SyntheticRequest:
        async def stream(self):
            for count in (512*1024,1,100):
                yielded.append(count)
                yield b"x"*count
    with pytest.raises(AppError):
        await read_moment_upload_content(SyntheticRequest(),512*1024)
    assert yielded==[512*1024,1]


@pytest.mark.asyncio
@pytest.mark.parametrize("posters", [None,1,"uuid",{},[False]])
async def test_draft_rejects_malformed_poster_lists(ctx,posters):
    app,settings=ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        response=await c.put("/api/v1/moments/draft",headers=auth(settings,"u1"),json={"payload":{"video_poster_media_ids":posters}})
        assert response.status_code==422

@pytest.mark.asyncio
async def test_completed_upload_has_durable_ref_and_expired_url_can_still_publish(poster_ctx):
    import json
    import time
    app,settings,storage=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        video=await upload(c,settings,purpose="video",content=VIDEO,mime="video/mp4")
        assert "media_ref" in video
        assert video["media_ref"].startswith("media://moments/u1/")
        assert video["media_cache_key"]
        with app.state.session_factory.begin() as s:
            row=s.get(MomentMediaUpload,video["id"])
            row.expires_at=datetime.now(timezone.utc)-timedelta(hours=1)
            payload=json.dumps({"domain":"moment-upload-v1","key":row.object_key,"upload":row.id,"viewer":"u1"},separators=(",",":"))
        token=storage._fernet.encrypt_at_time(payload.encode(),int(time.time())-3600).decode()
        expired_url="http://test/api/v1/moments/media/content/"+token
        assert (await c.get(expired_url)).status_code==404
        headers={**auth(settings,"u1"),"Idempotency-Key":"durable-publish"}
        posted=await c.post("/api/v1/moments",headers=headers,json={"visibility":"PUBLIC","video_urls":[expired_url]})
        assert posted.status_code==201
        assert posted.json()["video_cache_keys"]==[video["media_cache_key"]]
        replay=await c.post("/api/v1/moments",headers=headers,json={"visibility":"PUBLIC","video_urls":[video["media_ref"]]})
        assert replay.status_code==201 and replay.json()["id"]==posted.json()["id"]
        renewed=await c.post(f"/api/v1/moments/media/uploads/{video['id']}/complete",headers=headers)
        assert renewed.status_code==200
        assert renewed.json()["media_ref"]==video["media_ref"]
        assert (await c.get(renewed.json()["media_url"])).content==VIDEO
