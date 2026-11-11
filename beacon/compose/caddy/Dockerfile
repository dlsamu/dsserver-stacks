# Caddy with the Cloudflare DNS module (DNS-01 certificates without any inbound port).
# Official build method: the caddy "builder" image runs xcaddy; the result is copied into the
# official runtime image. Versions pinned by tag AND digest; Go verifies module checksums (sum.golang.org).
# Update: change the three versions (+ digests: docker buildx imagetools inspect caddy:<tag>), rebuild.
FROM docker.io/library/caddy:2.11.9-builder@sha256:1b828679ae08622c534d8e83ed80c6c25d343202f0586fe3b52d8e0ce33413b9 AS build
RUN xcaddy build v2.11.9 --with github.com/caddy-dns/cloudflare@v0.2.4

FROM docker.io/library/caddy:2.11.9@sha256:0c2243efcf437ab7f7a978f1027fcf0d4f9be8a75df27b1b3fbc5dbe0ffa8cf0
COPY --from=build /usr/bin/caddy /usr/bin/caddy
RUN caddy list-modules | grep -qx dns.providers.cloudflare
