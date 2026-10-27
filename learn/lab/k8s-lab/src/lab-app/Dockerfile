# syntax=docker/dockerfile:1
# Two stages: a full Go toolchain builds, and only the binary ships. The final
# image has no shell, no package manager, no libc — nothing to exploit and
# nothing for a scanner to flag.

FROM --platform=$BUILDPLATFORM golang:1.24-alpine AS build
ARG TARGETOS TARGETARCH VERSION=dev
WORKDIR /src
# go.mod first: this layer stays cached until the dependencies change.
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/lab-app .

# distroless/static: CA certificates, /etc/passwd with a nonroot user, tzdata.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/lab-app /lab-app
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/lab-app"]
