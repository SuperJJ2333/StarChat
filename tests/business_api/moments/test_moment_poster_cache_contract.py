import pytest
from httpx import ASGITransport, AsyncClient
from test_moment_video_posters import poster_ctx, upload
from test_moments_api import auth, ctx
from test_moment_video_media import VIDEO


@pytest.mark.asyncio
async def test_completed_poster_cache_identity_matches_published_dto(poster_ctx):
    app,settings,_=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as client:
        poster=await upload(client,settings)
        video=await upload(client,settings,purpose="video",content=VIDEO,mime="video/mp4")
        response=await client.post("/api/v1/moments",headers={**auth(settings,"u1"),"Idempotency-Key":"cache-identity"},json={"visibility":"SELF","video_urls":[video["media_ref"]],"video_poster_media_ids":[poster["id"]]})
        assert response.status_code==201
        assert response.json()["video_poster_cache_keys"]==[poster["media_cache_key"]]


@pytest.mark.asyncio
async def test_poster_limit_error_describes_its_actual_upload_limit(poster_ctx):
    app,settings,_=poster_ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as client:
        response=await client.post("/api/v1/moments/video-posters/uploads",headers={**auth(settings,"u1"),"Idempotency-Key":"poster-size"},json={"file_name":"synthetic.png","mime_type":"image/png","byte_size":512*1024+1})
        assert response.status_code==422
        assert "512KiB" in response.json()["error"]["message"]