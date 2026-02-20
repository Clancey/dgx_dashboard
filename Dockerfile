# Use a Dart container for compiling.
FROM dart:stable AS build

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

COPY . .
RUN dart compile exe bin/main.dart -o bin/dgx_dashboard

# Switch to a minimal Alpine container for runtime.
FROM alpine:latest

# Install Docker CLI, glibc compatibility, and util-linux for nsenter.
# gcompat is required for the glibc-linked Dart binary/nvidia-smi.
# nsenter is used to run journalctl/systemctl on the host (requires --pid=host).
RUN apk add --no-cache docker-cli gcompat util-linux

WORKDIR /app

# Copy the compiled binary and web assets
COPY --from=build /app/bin/dgx_dashboard ./dgx_dashboard
COPY --from=build /app/web ./web

EXPOSE 8080
ENTRYPOINT ["./dgx_dashboard"]
