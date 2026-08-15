# Layers the Fortress frontend fork's production build (Codebase/Fortress,
# `npm ci && make all`) onto the stock docker-jitsi-meet `web` image, which
# normally gets its frontend from the `jitsi-meet-web` apt package baked in
# at /usr/share/jitsi-meet (see docker-jitsi-meet/web/Dockerfile). There's no
# volume mount for that docroot, so this is the only way to serve a custom
# fork instead.
#
# Build context must be a directory containing exactly the output described
# in the EC2 bootstrap runbook (Fortress's own `libs/`/`build/` are excluded
# by Fortress/.dockerignore, so `make all`'s output has to be staged outside
# the Fortress repo first -- see bootstrap.sh). NOT built from the Fortress
# repo root directly.
#
# Tag this as exactly the reference docker-compose.yml already resolves
# `web` to (ghcr.io/jitsi/web:unstable by default) so Docker uses this local
# image with zero docker-compose.yml changes -- same trick already used for
# the custom Jibri build. Never run `docker compose pull` afterward on a box
# using this image; it would silently overwrite it with the stock upstream
# frontend.
#
#   docker build \
#     --build-arg BASE_IMAGE=ghcr.io/jitsi/web:unstable \
#     -t ghcr.io/jitsi/web:unstable \
#     -f web-fortress/Dockerfile \
#     ~/fortress-web-dist

ARG BASE_IMAGE=ghcr.io/jitsi/web:unstable
FROM ${BASE_IMAGE}

USER root

# Targeted per-directory copies, not a blanket `COPY . .` -- leaves the base
# image's /usr/share/jitsi-meet/.well-known symlink (-> /run/web/.well-known)
# and anything else it sets up outside these paths untouched.
COPY --chown=s6:s6 libs/         /usr/share/jitsi-meet/libs/
COPY --chown=s6:s6 css/all.css   /usr/share/jitsi-meet/css/all.css
COPY --chown=s6:s6 images/       /usr/share/jitsi-meet/images/
COPY --chown=s6:s6 fonts/        /usr/share/jitsi-meet/fonts/
COPY --chown=s6:s6 lang/         /usr/share/jitsi-meet/lang/
COPY --chown=s6:s6 sounds/       /usr/share/jitsi-meet/sounds/
COPY --chown=s6:s6 static/       /usr/share/jitsi-meet/static/
COPY --chown=s6:s6 index.html    /usr/share/jitsi-meet/index.html
COPY --chown=s6:s6 manifest.json /usr/share/jitsi-meet/manifest.json

# index.html pulls these in via nginx SSI (`<!--#include virtual="X" -->`).
# Without them, SSI silently falls through to the base image's own stock
# jitsi-meet-web versions -- e.g. title.html missing meant a staging join
# showed "Jitsi Meet" as the page title instead of Fortress's branding,
# with no error, just wrong content.
COPY --chown=s6:s6 head.html        /usr/share/jitsi-meet/head.html
COPY --chown=s6:s6 base.html        /usr/share/jitsi-meet/base.html
COPY --chown=s6:s6 fonts.html       /usr/share/jitsi-meet/fonts.html
COPY --chown=s6:s6 title.html       /usr/share/jitsi-meet/title.html
COPY --chown=s6:s6 plugin.head.html /usr/share/jitsi-meet/plugin.head.html
COPY --chown=s6:s6 body.html        /usr/share/jitsi-meet/body.html

# interface_config.js is NOT served from the docroot -- container startup
# runs `cp /defaults/interface_config.js /run/web/config/interface_config.js`
# (see web/rootfs/etc/s6-overlay/scripts/config), so /defaults/ is the real
# target, not /usr/share/jitsi-meet/. Earlier version of this Dockerfile
# skipped copying it anywhere, on the mistaken assumption that Fortress's
# interface_config.js was a placeholder -- it isn't: it has real, committed
# branding (APP_NAME, SHOW_JITSI_WATERMARK: false, JITSI_WATERMARK_LINK: '',
# etc.) that was silently missing from every prior staging build, showing
# stock Jitsi watermark/branding with no error.
COPY --chown=s6:s6 interface_config.js /defaults/interface_config.js

USER s6
