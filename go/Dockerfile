FROM --platform=$BUILDPLATFORM golang:1.26.10-trixie@sha256:909771fef53e3dcb0950255f0c9a8b4728c3b841e61509c7b29b098de7ee02d4 AS build

ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0
WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . ./
RUN mkdir -p /out \
    && GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/pithead ./cmd/pithead \
    && GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -o /out/dashboard ./cmd/dashboard

FROM scratch AS artifacts

COPY --from=build /out/pithead /pithead
COPY --from=build /out/dashboard /dashboard
