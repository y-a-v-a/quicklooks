# syntax=docker/dockerfile:1
# escape=\
ARG GO_VERSION=1.23

FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src
# a comment inside a continuation does not end it
RUN --mount=type=cache,target=/root/.cache/go-build \
    apk add --no-cache git && \
    # still part of the RUN above
    go build -o /out/app ./cmd/app

RUN <<EOF
set -eux
echo "FROM is not an instruction here"
EXPOSE 1234
EOF

COPY <<-"CONF" /etc/app.conf
	listen = $PORT
	CONF

FROM alpine:3.20
LABEL org.opencontainers.image.title="app # not a comment" version=1.0
ENV PATH="/app/bin:$PATH" MODE=production
COPY --from=build /out/app /app/bin/app
EXPOSE 8080/tcp 9090
HEALTHCHECK --interval=30s --retries=3 CMD wget -qO- http://localhost:8080/health || exit 1
ONBUILD RUN echo "child image"
USER 65534
ENTRYPOINT ["/app/bin/app", "--mode", "${MODE}"]
