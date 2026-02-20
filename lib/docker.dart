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

  /// Returns journalctl logs for a systemd service associated with a container.
  ///
  /// Uses nsenter to run journalctl on the host (requires --pid=host).
  /// The service name is derived from the container name (e.g., 'vllm_node'
  /// checks for 'vllm-*' services).
  Future<String> getServiceLogs(String containerName,
      {int lines = 200}) async {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(containerName)) {
      return 'Invalid container name';
    }

    // Find the vllm service name by listing matching services on the host
    final serviceName = await _findVllmService();
    if (serviceName == null) {
      return 'No vLLM systemd service found.\n\n'
          'To create one, use:\n'
          '  ./run-recipe.sh <recipe> --install-service';
    }

    try {
      final result = await Process.run('nsenter', [
        '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
        'journalctl', '-u', serviceName, '-n', lines.toString(), '--no-pager',
      ]);

      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        return output.isEmpty ? 'No logs available for $serviceName' : output;
      } else {
        return 'Error getting service logs: ${result.stderr}';
      }
    } catch (e) {
      return 'Error getting service logs: $e\n\n'
          'Ensure the dashboard is running with --pid=host';
    }
  }

  /// Starts a vLLM systemd service on the host via nsenter.
  Future<bool> startService() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return false;
    return _runHostSystemctl('start', serviceName);
  }

  /// Stops a vLLM systemd service on the host via nsenter.
  Future<bool> stopService() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return false;
    return _runHostSystemctl('stop', serviceName);
  }

  /// Returns the status of a vLLM systemd service, or null if not found.
  Future<String?> getServiceStatus() async {
    final serviceName = await _findVllmService();
    if (serviceName == null) return null;

    try {
      final result = await Process.run('nsenter', [
        '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
        'systemctl', 'is-active', serviceName,
      ]);
      return result.stdout.toString().trim();
    } catch (e) {
      return null;
    }
  }

  /// Find the first vllm-* systemd service on the host.
  Future<String?> _findVllmService() async {
    try {
      final result = await Process.run('nsenter', [
        '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
        'bash', '-c',
        'ls /etc/systemd/system/vllm-*.service 2>/dev/null | head -1',
      ]);

      if (result.exitCode == 0) {
        final path = result.stdout.toString().trim();
        if (path.isNotEmpty) {
          // Extract filename without .service extension path component
          final filename = path.split('/').last;
          return filename.replaceAll('.service', '');
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> _runHostSystemctl(String command, String serviceName) async {
    if (!RegExp(r'^[a-zA-Z0-9_.-]{1,255}$').hasMatch(serviceName)) {
      warning('Rejected systemctl command due to invalid service name: $serviceName');
      return false;
    }

    try {
      fine('Executing nsenter systemctl $command $serviceName');
      final result = await Process.run('nsenter', [
        '-t', '1', '-m', '-u', '-i', '-n', '-p', '--',
        'systemctl', command, serviceName,
      ]);
      fine('systemctl $command exited with code ${result.exitCode}');
      if (result.exitCode != 0) {
        warning('systemctl $command failed for $serviceName: ${result.stderr}');
      }
      return result.exitCode == 0;
    } catch (e) {
      error('Failed to run systemctl $command for $serviceName: $e');
      return false;
    }
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
