FROM dart:stable

# Note: nvidia-smi will be available from the host when using --gpus flag
# No need to install CUDA toolkit in the container

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
EXPOSE 8080
ENTRYPOINT ["dart", "bin/main.dart"]
