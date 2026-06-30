# Image with amulet-leveldb pre-installed, so the world-data tools
# (profile_report / account_map / audit_keys / apply_profile / restore_profile)
# run in seconds instead of compiling amulet-leveldb on every invocation.
#
# amulet-leveldb ships no wheel for cp311, so pip builds it from source — which needs
# g++ (present in the full python image, not -slim). It compiles cleanly on the host's
# native arch (arm64 included), so we no longer pin --platform: native arm64 runs the
# heightmap extraction ~40% faster than amd64 under emulation.
#
# Build:  just tools-build      Used by:  just _amulet
FROM python:3.11
RUN pip install --no-cache-dir amulet-leveldb
WORKDIR /scripts
