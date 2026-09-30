import importlib.util
import json
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location('s3_renderer', Path(__file__).parents[2] / 'infra/render_config.py')
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def settings(mode='s3'):
    return {'SYNAPSE_MEDIA_BLOB_BACKEND': mode, 'SYNAPSE_MEDIA_S3_BUCKET': 'starchat-media-218022113852-sg',
        'SYNAPSE_MEDIA_S3_REGION': 'ap-southeast-1', 'SYNAPSE_MEDIA_S3_PREFIX': 'synapse'}


def test_default_is_disabled():
    assert renderer.synapse_storage_provider({}) == ''


@pytest.mark.parametrize('mode,write', [('s3', True), ('local_s3_read', False)])
def test_provider_config_keeps_local_cache_and_lifecycle_aware_reads(mode, write):
    block = renderer.synapse_storage_provider(settings(mode))
    config = json.loads(block.partition(': ')[2])[0]
    assert config['module'] == 'synapse.media.chatflow_s3_storage.ChatFlowS3StorageProvider'
    assert config['store_local'] is True and config['store_remote'] is False
    assert config['store_synchronous'] is True
    assert config['config']['write_enabled'] is write
    assert 'secret' not in block.lower() and 'access_key' not in block.lower()


@pytest.mark.parametrize('field,value', [('SYNAPSE_MEDIA_BLOB_BACKEND', 'unknown'),
    ('SYNAPSE_MEDIA_S3_BUCKET',''), ('SYNAPSE_MEDIA_S3_BUCKET','x\nadmin: true'),
    ('SYNAPSE_MEDIA_S3_REGION','us-west-2'), ('SYNAPSE_MEDIA_S3_PREFIX','../business'),
    ('SYNAPSE_MEDIA_S3_PREFIX','business'), ('SYNAPSE_MEDIA_S3_ENDPOINT','http://example.com'),
    ('SYNAPSE_MEDIA_S3_ENDPOINT','https://user:secret@example.com'),
    ('SYNAPSE_MEDIA_S3_ENDPOINT','https://example.com/path')])
def test_unreviewed_config_is_rejected(field, value):
    data = settings()
    data[field] = value
    with pytest.raises(SystemExit):
        renderer.synapse_storage_provider(data)
