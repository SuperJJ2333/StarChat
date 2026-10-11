# R10 evidence identity patch — independent root review

Reviewed `9ee608a550b6ca745ef17925ae04abb08310dafe`, whose implementer did not approve their own patch. Product correction `0eea3319` had already passed the separate specification then quality review in `review.md`.

SPEC PASS: only two evidence files change. The immutable historical sample remains untouched. Metadata now names both original Windows CRLF bytes and archived Git LF bytes. The verifier accepts those two exact SHA256 identities, derives LF from CRLF, then derives CRLF from LF and verifies both hashes; it does not normalize arbitrary changed data into acceptance. Existing time, denominator, row-count and numeric equality assertions remain. This matches the recorded original sample's newline-only difference.

QUALITY PASS: read-byte hashing avoids platform text translation; JSON decoding accepts either recorded encoding. No network, user data, production sampler behavior or original values change. Implementer validated exact LF and CRLF exit0 plus a tampered sample exit1. Root additionally executed the verifier from the integrated tree after cherry-pick `7e325b4f`: exit0 and `LF/CRLF identities verified; four exact aggregate relabels; all denominators conserved.` This is evidence portability validation, not a new production sample or delivery SLO measurement.
