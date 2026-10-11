FROM matrixdotorg/sygnal@sha256:0e3ab79e04371964916f428a99b7fab19f23cbb16089112c4e7d8874c8f301ba

# Refuse an unexpected upstream layout or source before applying the overlay.
RUN python -c "import hashlib,sygnal.apnspushkin as a; assert hashlib.sha256(open(a.__file__,'rb').read()).hexdigest() == 'e87d32765b4d3f1cd24102ad25f87f1f4a53e8cd3666cc376798d915ab0131b9'"
COPY vendor/apnspushkin.py /usr/local/lib/python3.11/site-packages/sygnal/apnspushkin.py
COPY chatflow_ios_policy.py /usr/local/lib/python3.11/site-packages/sygnal/chatflow_ios_policy.py
COPY vendor/LICENSE /usr/local/share/licenses/chatflow-sygnal/LICENSE
LABEL org.opencontainers.image.description="Sygnal 0.15.1 with send-time iOS sound policy"
