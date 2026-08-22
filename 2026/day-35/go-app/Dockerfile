# Task 2 - multi-stage build.
# Stage 1 has the compiler. Stage 2 has only the binary.

# ---------- stage 1: build ----------
FROM golang:1.22-alpine AS builder

WORKDIR /src
COPY go.mod .
COPY main.go .

# CGO_ENABLED=0 produces a static binary with no libc dependency,
# which is what lets it run on a base image that has no libc at all.
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /src/hello main.go

# ---------- stage 2: runtime ----------
FROM alpine:3.20

# certificates are needed if the app ever makes outbound HTTPS calls
RUN apk add --no-cache ca-certificates

# non-root user
RUN adduser -D -u 10001 appuser

# copy ONLY the compiled binary out of the builder stage
COPY --from=builder /src/hello /usr/local/bin/hello

USER appuser
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/hello"]
