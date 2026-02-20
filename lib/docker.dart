import 'dart:convert';
import 'dart:io';

import 'utils.dart';

/// Represents a Docker container with status/details.
typedef DockerContainer = ({
  String id,
  String image,
  String command,
  String created,
  String status,
  String ports,
  String names,
  String cpu,
  String memory,
});

/// Monitors Docker containers using the `docker` command-line tool.
class DockerMonitor {
  /// Returns a list of all Docker containers.
  Future<List<DockerContainer>> getContainers() async {
    try {
      final listArgs = [
        'container',
        'ls',
        '--all',
        '--no-trunc',
        '--format',
        '{{.ID}}|{{.Image}}|{{.Command}}|{{.CreatedAt}}|{{.Status}}|{{.Ports}}|{{.Names}}',
      ];
      fine('Executing process: docker ${listArgs.join(' ')}');
      final result = await Process.run('docker', listArgs);
      fine('Process docker container ls exited with code ${result.exitCode}');

      if (result.exitCode != 0) {
        warning('docker container ls failed with code ${result.exitCode}');
        return [];
      }

      final output = result.stdout.toString().trim();
      final lines = output.split('\n');
      if (output.isEmpty || lines.isEmpty) {
        return [];
      }

      // Fetch stats to get CPU/Memory usage.
      final statsArgs = [
        'stats',
        '--all',
        '--no-stream',
        '--no-trunc',
        '--format',
        '{{.ID}}|{{.CPUPerc}}|{{.MemUsage}}',
      ];
      fine('Executing process: docker ${statsArgs.join(' ')}');
      final statsResult = await Process.run('docker', statsArgs);
      fine('Process docker stats exited with code ${statsResult.exitCode}');

      final statsMap = <String, ({String cpu, String memory})>{};
      if (statsResult.exitCode == 0) {
        final statsLines = statsResult.stdout.toString().trim().split('\n');
        for (final line in statsLines) {
          final parts = line.split('|');
          if (parts.length != 3) continue;

          final id = parts[0];
          statsMap[id] = (cpu: parts[1], memory: parts[2]);
        }
      } else {
        warning('docker stats failed with code ${statsResult.exitCode}');
      }

      final containers = <DockerContainer>[];
      for (final line in lines) {
        final parts = line.split('|');
        if (parts.length != 7) continue;

        final id = parts[0];
        final stats = statsMap[id];
        containers.add((
          id: id,
          image: parts[1],
          command: parts[2],
          created: parts[3],
          status: parts[4],
          ports: parts[5],
          names: parts[6],
          cpu: stats?.cpu ?? '--',
          memory: stats?.memory ?? '--',
        ));
      }
      return containers;
    } catch (e) {
      error('Failed to query docker containers: $e');
      return [];
    }
  }

  /// Restarts the container with [id].
  Future<bool> restartContainer(String id) => _runDockerCommand('restart', id);

  /// Starts the container with [id].
  Future<bool> startContainer(String id) => _runDockerCommand('start', id);

  /// Stops the container with [id].
  Future<bool> stopContainer(String id) => _runDockerCommand('stop', id);

  /// Returns logs for the container with [id].
  Future<String> getLogs(String id, {int tail = 100}) async {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(id)) {
      return 'Invalid container ID';
    }

    try {
      final result = await Process.run('docker', [
        'logs',
        '--tail',
        tail.toString(),
        id,
      ]);

      if (result.exitCode == 0) {
        return result.stdout.toString();
      } else {
        return 'Error getting logs: ${result.stderr}';
      }
    } catch (e) {
      return 'Error getting logs: $e';
    }
  }

  /// Returns a stream of logs for the container with [id].
  /// Set [follow] to true to stream logs in real-time.
  Stream<String> streamLogs(String id, {bool follow = false}) async* {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(id)) {
      yield 'Invalid container ID';
      return;
    }
    final args = follow ? ['logs', '--follow', id] : ['logs', id];
    final process = await Process.start('docker', args);

    await for (final line
        in process.stdout
            .transform(utf8.decoder)
            .takeWhile((line) => line.isNotEmpty)) {
      yield line;
    }

    final stderr = await process.stderr.transform(utf8.decoder).join();
    if (stderr.isNotEmpty) {
      yield 'Error: $stderr';
    }
  }

  // ---------------------------------------------------------------------------
  // Host command execution
  //
  // The dashboard runs inside Docker. To access host systemd services
  // (journalctl, systemctl) we run commands on the host.
  //
  // Strategy (tried in order, result cached):
  //   1. nsenter directly (needs --pid=host AND --privileged/CAP_SYS_ADMIN)
  //   2. docker run a privileged helper container using our own image
  //      (needs docker socket — always mounted for container monitoring)
  //   3. Direct execution (for when dashboard runs natively, not in Docker)
  // ---------------------------------------------------------------------------

  /// Cached strategy: 'nsenter', 'docker', 'direct', or null (not probed).
  String? _hostExecStrategy;

  /// Cached image name for the 'docker' strategy helper container.
  String? _ownImageName;

  /// Detect our own Docker image name so we can use it for helper containers.
  /// This avoids pulling external images and guarantees nsenter is available.
  Future<String?> _getOwnImageName() async {
    if (_ownImageName != null) return _ownImageName;

    try {
      // In Docker, hostname is the container ID.
      final hostname = Platform.localHostname;
      final result = await Process.run('docker', [
        'inspect', '--format', '{{.Config.Image}}', hostname,
      ]);
      if (result.exitCode == 0) {
        final image = result.stdout.toString().trim();
        if (image.isNotEmpty) {
          _ownImageName = image;
          fine('Detected own image: $image');
          return image;
        }
      }
    } catch (_) {}

    // Fallback: try common name
    _ownImageName = 'dgx_dashboard';
    return _ownImageName;
  }

  /// Run a command on the host and return its stdout.
  /// Returns null on failure.
  Future<String?> _runOnHost(List<String> command) async {
    if (_hostExecStrategy != null) {
      return _runOnHostWith(_hostExecStrategy!, command);
    }

    // Probe each strategy. The test must verify we're actually on the HOST
    // (not just inside our container). We check for /etc/systemd which exists
    // on the Ubuntu host but not inside our Alpine container.
    for (final strategy in ['nsenter', 'docker', 'direct']) {
      info('Probing host command strategy: $strategy ...');
      final result = await _runOnHostWith(
        strategy,
        ['sh', '-c', 'test -d /etc/systemd && echo host-ok'],
      );
      if (result != null && result.trim() == 'host-ok') {
        _hostExecStrategy = strategy;
        info('Host command strategy: $strategy');
        return _runOnHostWith(strategy, command);
      }
      info('Probe failed for strategy: $strategy '
          '(result: ${result?.trim() ?? 'null'})');
    }

    warning('All host command strategies failed');
    return null;
  }

  Future<String?> _runOnHostWith(String strategy, List<String> command) async {
    try {
      ProcessResult result;
      switch (strategy) {
        case 'nsenter':
          // Direct nsenter — requires --pid=host AND --privileged on our
          // container (or at least CAP_SYS_ADMIN).
          result = await Process.run('nsenter', [
            '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
            ...command,
          ]);
        case 'docker':
          // Spawn a privileged helper container using our own image (which
          // has nsenter from util-linux). The helper gets --pid=host and
          // --privileged so nsenter works from inside it.
          // We override the entrypoint to nsenter so the dashboard binary
          // doesn't run.
          final image = await _getOwnImageName();
          if (image == null) return null;
          result = await Process.run('docker', [
            'run', '--rm', '--pid=host', '--privileged', '--net=host',
            '--entrypoint', 'nsenter',
            image,
            '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
            ...command,
          ]);
        case 'direct':
          result = await Process.run(command.first, command.skip(1).toList());
        default:
          return null;
      }

      if (result.exitCode == 0) {
        return result.stdout.toString();
      }
      // systemctl is-active returns exit code 3 for "inactive" — still valid.
      if (command.contains('is-active')) {
        return result.stdout.toString();
      }
      info('$strategy failed (exit ${result.exitCode}): '
          '${result.stderr.toString().trim()}');
      return null;
    } catch (e) {
      info('$strategy error: $e');
      return null;
    }
  }

  /// Returns journalctl logs for the vLLM systemd service.
  Future<String> getServiceLogs(String containerName,
      {int lines = 200}) async {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(containerName)) {
      return 'Invalid container name';
    }

    final serviceName = await _findVllmService();
    if (serviceName == null) {
      return 'No vLLM systemd service found.\n\n'
          'To create one, use:\n'
          '  ./run-recipe.sh <recipe> --install-service';
    }

    final output = await _runOnHost([
      'journalctl', '-u', serviceName,
      '-n', lines.toString(), '--no-pager',
    ]);

    if (output == null) {
      return 'Failed to read service logs.\n\n'
          'Ensure the dashboard has the Docker socket mounted:\n'
          '  -v /var/run/docker.sock:/var/run/docker.sock';
    }

    return output.isEmpty ? 'No logs available for $serviceName' : output;
  }

  /// Starts a vLLM systemd service on the host.
  Future<bool> startService() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return false;
    final result = await _runOnHost(['systemctl', 'start', serviceName]);
    return result != null;
  }

  /// Stops a vLLM systemd service on the host.
  Future<bool> stopService() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return false;
    final result = await _runOnHost(['systemctl', 'stop', serviceName]);
    return result != null;
  }

  /// Returns the status of a vLLM systemd service, or null if not found.
  Future<String?> getServiceStatus() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return null;

    final result = await _runOnHost(['systemctl', 'is-active', serviceName]);
    return result?.trim();
  }

  /// Find the first vllm-* systemd service on the host.
  Future<String?> _findVllmService() async {
    final result = await _runOnHost([
      'bash', '-c',
      'ls /etc/systemd/system/vllm-*.service 2>/dev/null | head -1',
    ]);

    if (result != null) {
      final path = result.trim();
      if (path.isNotEmpty) {
        final filename = path.split('/').last;
        return filename.replaceAll('.service', '');
      }
    }
    return null;
  }

  Future<bool> _runDockerCommand(String command, String id) async {
    // Ensure a valid container id (alphanumeric, underscore, hyphen, period).
    // Must be 1-255 chars, no path separators or shell metacharacters.
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(id)) {
      warning('Rejected docker command due to invalid container id: $id');
      return false;
    }

    try {
      final args = [command, id];
      fine('Executing process: docker ${args.join(' ')}');
      final result = await Process.run('docker', args);
      fine('Process docker $command exited with code ${result.exitCode}');
      if (result.exitCode != 0) {
        warning('docker $command failed for $id with code ${result.exitCode}');
      }
      return result.exitCode == 0;
    } catch (e) {
      error('Failed to run docker $command for $id: $e');
      return false;
    }
  }
}
