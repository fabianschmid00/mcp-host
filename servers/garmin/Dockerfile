# syntax=docker/dockerfile:1
# garmin_mcp (https://github.com/taxuspt/garmin_mcp) has no published image,
# so we build one from a pinned commit. The git commit hash pins the source;
# uv.lock (--frozen) pins every dependency version and hash.
ARG GARMIN_MCP_COMMIT=cfc5d799ab0f165e837f1188a1d093c65838aaf7

FROM scratch AS src
ARG GARMIN_MCP_COMMIT
ADD --keep-git-dir=false https://github.com/taxuspt/garmin_mcp.git#${GARMIN_MCP_COMMIT} /

FROM ghcr.io/astral-sh/uv:0.12.23@sha256:61d393e44e249f2e4b526b6c7ddcecce245946826e608e11c93ad4f5bba55b21 AS uv

FROM python:3.13-slim@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c AS build
COPY --from=uv /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app
COPY --from=src /pyproject.toml /uv.lock /README.md ./
COPY --from=src /src ./src
RUN uv sync --frozen --no-dev --no-editable
COPY requirements-overrides.txt ./
RUN uv pip install --python /app/.venv/bin/python --no-deps --require-hashes -r requirements-overrides.txt

FROM python:3.13-slim@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c
# Same base and /app prefix as the build stage: the venv holds absolute paths.
COPY --from=build /app/.venv /app/.venv
# /data is the token volume. A named volume inherits this ownership on first use.
RUN install -d -o 10001 -g 10001 -m 0700 /data
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER 10001:10001
ENTRYPOINT ["garmin-mcp"]
