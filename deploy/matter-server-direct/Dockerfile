FROM ghcr.io/matter-js/matterjs-server@sha256:ee149c7c67eff0e90f131e8f0d628f7b099591ec58473c8cda1209e8ae4df66e

USER root
COPY patch-direct-invoke.mjs /tmp/patch-direct-invoke.mjs
RUN node /tmp/patch-direct-invoke.mjs && rm /tmp/patch-direct-invoke.mjs
USER 1000:1000
