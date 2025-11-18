import 'dart:async';
import 'dart:io';

import 'package:dgx_dashboard/cpu.dart';
import 'package:dgx_dashboard/docker.dart';
import 'package:dgx_dashboard/gpu.dart';
import 'package:dgx_dashboard/memory.dart';
import 'package:dgx_dashboard/server.dart';
import 'package:dgx_dashboard/temps.dart';

Future<void> main() async {
  final server = Server(
    GpuMonitor(),
    CpuMonitor(),
    MemoryMonitor(),
    TemperatureMonitor(),
    DockerMonitor(),
  );
  await server.start(InternetAddress.anyIPv4, 8080);
}
