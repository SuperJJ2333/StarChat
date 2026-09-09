FROM matrixdotorg/synapse:v1.132.0@sha256:3036ec25dfb5fcc5120942465788c1e1f2bb3671e28b04d7b3a1db4400ac84f4

COPY apply_patch.py chatflow_media_dedup.py 99_chatflow_media.sql upstream-manifest.json /opt/chatflow-media/
COPY patches/ /opt/chatflow-media/patches/
RUN python /opt/chatflow-media/apply_patch.py
