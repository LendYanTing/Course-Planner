# --- build stage -------------------------------------------------------------
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

# --- run stage ---------------------------------------------------------------
FROM alpine:3.20
RUN adduser -D -H appuser && apk add --no-cache ca-certificates tzdata
USER appuser
WORKDIR /app
COPY --from=build /out/server /app/server
EXPOSE 8080
ENTRYPOINT ["/app/server"]
