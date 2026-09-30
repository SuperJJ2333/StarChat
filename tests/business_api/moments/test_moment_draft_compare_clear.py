import pytest
from httpx import ASGITransport, AsyncClient
from test_moments_api import auth, ctx


@pytest.mark.asyncio
async def test_clear_draft_only_if_entire_owner_payload_unchanged(ctx):
    app,settings=ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        headers=auth(settings,"u1")
        expected={"text":"synthetic","visibility":"SELF","nested":{"keep":True},"selected":["a","b"]}
        saved=await c.put("/api/v1/moments/draft",headers=headers,json={"payload":expected})
        assert saved.status_code==200
        changed={**expected,"text":"newer edit"}
        await c.put("/api/v1/moments/draft",headers=headers,json={"payload":changed})
        stale=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":expected})
        assert stale.status_code==200 and stale.json()=={"cleared":False}
        assert (await c.get("/api/v1/moments/draft",headers=headers)).json()==changed
        other=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=auth(settings,"u2"),json={"expected_payload":changed})
        assert other.status_code==200 and other.json()=={"cleared":False}
        cleared=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":changed})
        assert cleared.status_code==200 and cleared.json()=={"cleared":True}
        assert (await c.get("/api/v1/moments/draft",headers=headers)).status_code==404
        repeat=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":changed})
        assert repeat.json()=={"cleared":False}


@pytest.mark.asyncio
async def test_draft_compare_is_json_exact_and_legacy_delete_still_works(ctx):
    app,settings=ctx
    async with AsyncClient(transport=ASGITransport(app=app),base_url="http://test") as c:
        headers=auth(settings,"u1")
        await c.put("/api/v1/moments/draft",headers=headers,json={"payload":{"value":True}})
        response=await c.post("/api/v1/moments/draft/clear-if-unchanged",headers=headers,json={"expected_payload":{"value":1}})
        assert response.status_code==200 and response.json()=={"cleared":False}
        assert (await c.get("/api/v1/moments/draft",headers=headers)).status_code==200
        assert (await c.post("/api/v1/moments/draft/clear-if-unchanged",json={"expected_payload":{"value":True}})).status_code==401
        assert (await c.delete("/api/v1/moments/draft",headers=headers)).status_code==204
