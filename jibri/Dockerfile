ARG JITSI_REPO=ghcr.io/jitsi
ARG BASE_TAG=latest

# Fortress (FOR-59): build jibri from Codebase/jibri -- this repo's vendored, patched fork
# of jitsi/jibri (see FileSink.kt's segment-recording support) -- instead of installing the
# upstream jibri .deb, so the segmented-MKV crash-safe capture patch actually ships. Built
# from the "jibri-src" named build context (see the Makefile's --build-context flag), since
# Codebase/jibri lives outside this Dockerfile's own build context (docker-jitsi-meet/jibri).
FROM maven:3.9-eclipse-temurin-17 AS jibri-builder
COPY --from=jibri-src . /build
WORKDIR /build
RUN mvn -B -DskipTests clean package && \
    mv target/*-jar-with-dependencies.jar target/jibri.jar

FROM ${JITSI_REPO}/base-java:${BASE_TAG}

USER root

LABEL org.opencontainers.image.title="Jitsi Broadcasting Infrastructure (jibri)"
LABEL org.opencontainers.image.description="Components for recording and/or streaming a conference."
LABEL org.opencontainers.image.url="https://github.com/jitsi/jibri"
LABEL org.opencontainers.image.source="https://github.com/jitsi/docker-jitsi-meet"
LABEL org.opencontainers.image.documentation="https://jitsi.github.io/handbook/"

ARG USE_CHROMIUM=0
#ARG CHROME_RELEASE=latest
# https://googlechromelabs.github.io/chrome-for-testing/
ARG CHROME_RELEASE=149.0.7827.114

COPY rootfs/ /
COPY --from=jibri-builder /build/target/jibri.jar /opt/jitsi/jibri/jibri.jar

# Fortress (FOR-59): the two dotfiles the upstream jibri .deb's postinst script used to move
# into jibri's home directory (see Codebase/jibri/debian/postinst) -- carried over by hand
# since we no longer install that package. icewm.preferences (ShowTaskBar=0) configures the
# desktop; asoundrc is the ALSA loopback config for the .deb's alsa-based audio-source
# (unused here, since this image captures via pulse -- kept for parity with upstream).
COPY --from=jibri-src resources/debian-package/etc/jitsi/jibri/asoundrc /tmp/jibri-asoundrc
COPY --from=jibri-src resources/debian-package/etc/jitsi/jibri/icewm.preferences /tmp/jibri-icewm.preferences

RUN \
  apt-dpkg-wrap apt-get update && \
  apt-dpkg-wrap apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    alsa-utils \
    dbus \
    dbus-x11 \
    ffmpeg \
    fonts-noto \
    fonts-noto-cjk \
    icewm \
    jitsi-autoscaler-sidecar \
    jitsi-upload-integrations \
    jq \
    libcap2-bin \
    libgl1-mesa-dri \
    procps \
    pulseaudio \
    rclone \
    rtkit \
    unzip \
    xserver-xorg-video-dummy \
    && \
  /usr/bin/install-chrome.sh && \
  apt-get purge -y \
    unzip \
    && \
  apt-cleanup && \
\
  rm -rf /etc/jitsi/jibri && \
  ln -s /run/jibri/config /etc/jitsi/jibri && \
\
  # Fortress (FOR-59): /var/log/jitsi itself (not just the jibri subdir) used to be created
  # by the jibri .deb's postinst -- now that we don't install that package, nothing else
  # creates the parent dir, so the ln below would fail without this.
  mkdir -p /var/log/jitsi && \
  rm -rf /var/log/jitsi/jibri && \
  ln -s /storage/logs /var/log/jitsi/jibri && \
\
  mkdir -p /storage && \
  chown s6:s6 /storage && \
\
  # Fortress (FOR-59): create the jibri system user/group ourselves -- previously done by
  # the jibri .deb's postinst when we still `apt-get install jibri` (see
  # Codebase/jibri/debian/postinst for the script this replicates). Parenthesized so this
  # check's own "||" fallback can't be hijacked by an unrelated failure earlier in this
  # long "&&" chain (an earlier failure would otherwise short-circuit straight through to
  # unconditionally running groupadd here, masking the real error).
  (getent group jitsi > /dev/null || groupadd jitsi) && \
  useradd --system --create-home jibri && \
  usermod -a -G jibri,jitsi,audio,video jibri && \
  mv /tmp/jibri-asoundrc /home/jibri/.asoundrc && \
  mkdir -p /home/jibri/.icewm && \
  mv /tmp/jibri-icewm.preferences /home/jibri/.icewm/preferences && \
\
  usermod -a -G audio,jibri,jitsi,rtkit,video s6 && \
  cp -r /home/jibri/. /home/s6 && \
  rm -rf /home/jibri && \
  rm -rf /home/s6/.cache /home/s6/.config /home/s6/.local && \
  ln -s /run/tmp/s6-cache /home/s6/.cache && \
  ln -s /run/tmp/s6-config /home/s6/.config && \
  ln -s /run/tmp/s6-local /home/s6/.local && \
  chown -h s6:s6 /home/s6/.cache /home/s6/.config /home/s6/.local && \
  chown s6:s6 /home/s6 -R && \
\
  dpkgArch="$(dpkg --print-architecture)" && \
  case "${dpkgArch##*-}" in \
    "amd64") SC_ARCH=x86_64 ;; \
    "arm64") SC_ARCH=aarch64 ;; \
    *) echo "unsupported architecture"; exit 1 ;; \
  esac && \
  wget -qO /usr/bin/shm-check https://github.com/saghul/shm-check/releases/download/v1.0.0/shm-check-${SC_ARCH} && \
  chmod +x /usr/bin/shm-check

VOLUME /config

USER s6
