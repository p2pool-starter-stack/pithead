FROM --platform=$BUILDPLATFORM golang:1.26.10-trixie@sha256:909771fef53e3dcb0950255f0c9a8b4728c3b841e61509c7b29b098de7ee02d4 AS build

ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0
WORKDIR /src

COPY . ./
RUN mkdir -p /out \
    && GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -buildvcs=false -ldflags=-buildid= -o /out/pithead ./cmd/pithead

FROM scratch AS artifacts

COPY --from=build /out/pithead /pithead
