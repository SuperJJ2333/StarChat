"""反转带图朋友圈测试断言（一次性脚本）。"""
from pathlib import Path

p = Path("tests/business_api/moments/test_moments_api.py")
src = p.read_text(encoding="utf-8")

old = '''async def test_create_with_images_returns_dto_without_not_found(ctx):
    """带图动态为 PENDING_REVIEW：创建接口必须直接返回 DTO，而非 404。"""
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'img-1'}, json={'text': '带图动态', 'visibility': 'PUBLIC', 'image_urls': ['https://media.example.test/p1.jpg']})
        assert created.status_code == 201
        body = created.json()
        assert body['text'] == '带图动态'
        assert body['status'] == 'PENDING_REVIEW'
'''

new = '''async def test_create_with_images_publishes_immediately_and_shows_in_feed(ctx):
    """带图动态与纯文字一致直接 PUBLISHED 并出现在 feed（历史缺陷：
    带图被置 PENDING_REVIEW 且无审核放行流程，导致永远不可见）。"""
    app, settings = ctx
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        created = await client.post('/api/v1/moments', headers={**auth(settings, 'u1'), 'Idempotency-Key': 'img-1'}, json={'text': '带图动态', 'visibility': 'PUBLIC', 'image_urls': ['https://media.example.test/p1.jpg']})
        assert created.status_code == 201
        body = created.json()
        assert body['text'] == '带图动态'
        assert body['status'] == 'PUBLISHED'
        assert body['image_urls'] == ['https://media.example.test/p1.jpg']

        feed = await client.get('/api/v1/moments/feed?mode=latest', headers=auth(settings, 'u2'))
        assert feed.status_code == 200
        shown = [item for item in feed.json()['items'] if item['id'] == body['id']]
        assert len(shown) == 1, '带图动态必须出现在好友 feed 中'
        assert shown[0]['image_urls'] == ['https://media.example.test/p1.jpg']
'''

assert src.count(old) == 1, "old block not found"
src = src.replace(old, new)
p.write_text(src, encoding="utf-8", newline="\n")
print("test updated")
