FROM matrixdotorg/synapse:v1.132.0@sha256:3036ec25dfb5fcc5120942465788c1e1f2bb3671e28b04d7b3a1db4400ac84f4

RUN python -m pip install --no-cache-dir boto3==1.40.40 botocore==1.40.40 s3transfer==0.14.0 jmespath==1.0.1 python-dateutil==2.9.0.post0 six==1.17.0 urllib3==2.8.0 \
    && python -m pip check

COPY apply_patch.py chatflow_media_dedup.py chatflow_s3_storage.py chatflow_s3_backfill.py 99_chatflow_media.sql upstream-manifest.json /opt/chatflow-media/
COPY patches/ /opt/chatflow-media/patches/
RUN python /opt/chatflow-media/apply_patch.py

COPY chatflow_mobile_login.py /opt/chatflow-mobile/chatflow_mobile_login.py
RUN python -c "import shutil, sysconfig; from pathlib import Path; target=Path(sysconfig.get_paths()['purelib'])/'chatflow_mobile_login.py'; shutil.copyfile('/opt/chatflow-mobile/chatflow_mobile_login.py', target); target.chmod(0o644); target.parent.chmod(0o755); Path('/opt/chatflow-mobile').chmod(0o755)"

# Communications custody is disabled until its explicit config/provider gates pass.
RUN python -m pip install --no-cache-dir cryptography==43.0.3 PyNaCl==1.5.0 \
    && python -m pip check
COPY chatflow_recovery_vault.py chatflow_recovery_crypto.py chatflow_recovery_store.py chatflow_recovery_migrate.py chatflow_recovery_provider.py /opt/chatflow-recovery/
COPY recovery_migrations/ /opt/chatflow-recovery/recovery_migrations/
COPY recovery-v1.schema.json /opt/chatflow-recovery/recovery-v1.schema.json
RUN python -c "import shutil, sysconfig; from pathlib import Path; source=Path('/opt/chatflow-recovery'); target=Path(sysconfig.get_paths()['purelib']); [shutil.copyfile(p, target/p.name) for p in source.glob('chatflow_recovery_*.py')]; [(target/p.name).chmod(0o644) for p in source.glob('chatflow_recovery_*.py')]; source.chmod(0o755); [p.chmod(0o644) for p in source.glob('*') if p.is_file()]"
