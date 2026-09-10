FROM matrixdotorg/synapse:v1.132.0@sha256:3036ec25dfb5fcc5120942465788c1e1f2bb3671e28b04d7b3a1db4400ac84f4

COPY apply_patch.py chatflow_media_dedup.py 99_chatflow_media.sql upstream-manifest.json /opt/chatflow-media/
COPY patches/ /opt/chatflow-media/patches/
RUN python /opt/chatflow-media/apply_patch.py

COPY chatflow_mobile_login.py /opt/chatflow-mobile/chatflow_mobile_login.py
RUN python -c "import shutil, sysconfig; from pathlib import Path; target=Path(sysconfig.get_paths()['purelib'])/'chatflow_mobile_login.py'; shutil.copyfile('/opt/chatflow-mobile/chatflow_mobile_login.py', target); target.chmod(0o644); target.parent.chmod(0o755); Path('/opt/chatflow-mobile').chmod(0o755)"
