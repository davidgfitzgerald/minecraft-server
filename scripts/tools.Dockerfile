# Image with amulet-leveldb pre-installed, so the world-data tools
# (profile_report / account_map / audit_keys / apply_profile / restore_profile)
# run in seconds instead of compiling amulet-leveldb on every invocation.
#
# amulet-leveldb has no arm64 wheel and no amd64 wheel for cp311, so pip builds
# it from source — which needs g++ (present in the full python image, not -slim).
# Built/used under --platform linux/amd64 (the only platform it compiles on here).
#
# Build:  just tools-build      Used by:  just _amulet
FROM python:3.11
RUN pip install --no-cache-dir amulet-leveldb
WORKDIR /scripts
