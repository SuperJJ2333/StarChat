import pytest
from httpx import ASGITransport, AsyncClient
from test_moments_api import auth, ctx
from test_moment_video_posters import poster_ctx, upload
from test_moment_video_media import VIDEO


@pytest.mark.asyncio
async def test_reopened_get_video_draft_publish_then_compare_clear(poster_ctx):
    app, settings, _ = poster_ctx
    headers = auth(settings, "u1")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        video = await upload(client, settings, purpose="video", content=VIDEO, mime="video/mp4")
        poster = await upload(client, settings)
        payload = {"text": "reopened", "visibility": "SELF", "video_urls": [video["media_ref"]],
                   "video_poster_media_ids": [poster["id"]], "nested": {"flag": True}}
        saved = await client.put("/api/v1/moments/draft", headers=headers, json={"payload": payload})
        assert saved.status_code == 200
        reopened = await client.get("/api/v1/moments/draft", headers=headers)
        assert reopened.status_code == 200
        expected = reopened.json()
        assert expected["video_urls"] != saved.json()["video_urls"]
        published = await client.post("/api/v1/moments", headers={**headers, "Idempotency-Key": "get-draft-publish"},
                                      json={key: value for key, value in expected.items() if key != "nested"})
        assert published.status_code == 201
        cleared = await client.post("/api/v1/moments/draft/clear-if-unchanged", headers=headers,
                                    json={"expected_payload": expected})
        assert cleared.status_code == 200
        assert cleared.json() == {"cleared": True}
        assert (await client.get("/api/v1/moments/draft", headers=headers)).status_code == 404


@pytest.mark.asyncio
async def test_get_snapshot_cannot_clear_newer_metadata_or_foreign_video(poster_ctx):
    app, settings, _ = poster_ctx
    headers = auth(settings, "u1")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        video = await upload(client, settings, purpose="video", content=VIDEO, mime="video/mp4")
        payload = {"text": "same", "video_urls": [video["media_ref"]], "nested": {"flag": True}}
        await client.put("/api/v1/moments/draft", headers=headers, json={"payload": payload})
        old = (await client.get("/api/v1/moments/draft", headers=headers)).json()
        newer = {**payload, "nested": {"flag": 1}}
        await client.put("/api/v1/moments/draft", headers=headers, json={"payload": newer})
        result = await client.post("/api/v1/moments/draft/clear-if-unchanged", headers=headers, json={"expected_payload": old})
        assert result.json() == {"cleared": False}
        foreign = await upload(client, settings, owner="u2", purpose="video", content=VIDEO, mime="video/mp4")
        result = await client.post("/api/v1/moments/draft/clear-if-unchanged", headers=headers,
                                   json={"expected_payload": {**newer, "video_urls": [foreign["media_ref"]]}})
        assert result.json() == {"cleared": False}
        current = await client.get("/api/v1/moments/draft", headers=headers)
        assert current.status_code == 200 and current.json()["nested"] == {"flag": 1}


@pytest.mark.asyncio
async def test_owned_image_identity_equivalence_keeps_media_order_exact(poster_ctx):
    app, settings, _ = poster_ctx
    headers = auth(settings, "u1")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        first = await upload(client, settings, purpose="image")
        second = await upload(client, settings, purpose="image")
        payload = {"image_urls": [first["media_url"], second["media_url"]], "text": "same"}
        await client.put("/api/v1/moments/draft", headers=headers, json={"payload": payload})
        reordered = {**payload, "image_urls": [second["media_ref"], first["media_ref"]]}
        stale = await client.post("/api/v1/moments/draft/clear-if-unchanged", headers=headers,
                                  json={"expected_payload": reordered})
        assert stale.json() == {"cleared": False}
        same = {**payload, "image_urls": [first["media_ref"], second["media_ref"]]}
        cleared = await client.post("/api/v1/moments/draft/clear-if-unchanged", headers=headers,
                                    json={"expected_payload": same})
        assert cleared.json() == {"cleared": True}
