import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/recording_api.dart';
import '../app_state.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key});

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

enum _RecordingNoticeLevel { info, warning, error }

class _RecordingScreenState extends State<RecordingScreen> {
  RecordingStatus? _status;
  List<RecordingScreenInfo> _screens = const [];
  bool _loading = true;

  int? _screenIndex;
  int? _screenDisplayId;

  String? _recordingNotice;
  _RecordingNoticeLevel _recordingNoticeLevel = _RecordingNoticeLevel.info;
  bool _showAdvanced = false;

  Timer? _pollTimer;
  AppState? _appState;
  int _lastRecordingStatusVersion = -1;
  int _lastCurrentTabIndex = -1;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _appState = context.read<AppState>();
      _lastRecordingStatusVersion = _appState!.recordingStatusVersion;
      _lastCurrentTabIndex = _appState!.currentTabIndex;
      _appState!.addListener(_onAppStateChanged);
    });
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _pollTimer?.cancel();
    super.dispose();
  }

  void _onAppStateChanged() {
    if (!mounted || _appState == null) return;
    final currentTabIndex = _appState!.currentTabIndex;
    if (currentTabIndex != _lastCurrentTabIndex) {
      _lastCurrentTabIndex = currentTabIndex;
      if (currentTabIndex == 0) {
        _load();
      } else {
        _stopPolling();
      }
    }

    final currentVersion = _appState!.recordingStatusVersion;
    if (currentVersion != _lastRecordingStatusVersion) {
      _lastRecordingStatusVersion = currentVersion;
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final appState = context.read<AppState>();
      final status = await appState.loadRecordingStatusForUi();
      await appState.syncRecordingStateFromBackend(status.isRecording);
      final screens = await appState.loadAvailableScreensForUi();
      await appState.refreshPermissionStatus();

      if (!mounted) {
        return;
      }

      setState(() {
        _status = status;
        _screens = screens;
        _loading = false;

        final selected = _resolveSelectedScreen(screens);
        _screenIndex = selected?.index;
        _screenDisplayId = selected?.displayId;
      });

      if (status.isRecording) {
        _startPolling();
      } else {
        _stopPolling();
      }

      _consumePendingRecordingNotice(showSnackBar: true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  RecordingScreenInfo? _resolveSelectedScreen(
      List<RecordingScreenInfo> screens) {
    if (screens.isEmpty) return null;
    if (_screenIndex == null) return null;

    for (final screen in screens) {
      if (screen.index == _screenIndex) {
        return screen;
      }
    }

    final primary = screens.where((screen) => screen.isPrimary);
    if (primary.isNotEmpty) {
      return primary.first;
    }
    return screens.first;
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final appState = _appState;
      if (appState == null || !mounted || appState.currentTabIndex != 0) {
        return;
      }
      _load();
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  _RecordingNoticeLevel _classifyNoticeLevel(String notice) {
    final lower = notice.toLowerCase();
    if (lower.contains('permission') ||
        lower.contains('failed') ||
        lower.contains('did not') ||
        lower.contains('cancelled') ||
        lower.contains('without creating')) {
      return _RecordingNoticeLevel.error;
    }
    if (lower.contains('without audio') ||
        lower.contains('microphone only') ||
        lower.contains('import warning')) {
      return _RecordingNoticeLevel.warning;
    }
    return _RecordingNoticeLevel.info;
  }

  void _showRecordingNotice(String notice, {bool showSnackBar = true}) {
    final trimmed = notice.trim();
    if (trimmed.isEmpty || !mounted) {
      return;
    }
    final level = _classifyNoticeLevel(trimmed);
    setState(() {
      _recordingNotice = trimmed;
      _recordingNoticeLevel = level;
    });

    if (!showSnackBar) {
      return;
    }

    final colorScheme = Theme.of(context).colorScheme;
    final snackColor = switch (level) {
      _RecordingNoticeLevel.error => colorScheme.errorContainer,
      _RecordingNoticeLevel.warning => colorScheme.tertiaryContainer,
      _RecordingNoticeLevel.info => colorScheme.surfaceContainerHighest,
    };
    final textColor = switch (level) {
      _RecordingNoticeLevel.error => colorScheme.onErrorContainer,
      _RecordingNoticeLevel.warning => colorScheme.onTertiaryContainer,
      _RecordingNoticeLevel.info => colorScheme.onSurface,
    };

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: snackColor,
        content: Text(trimmed, style: TextStyle(color: textColor)),
      ),
    );
  }

  void _consumePendingRecordingNotice({bool showSnackBar = true}) {
    final notice = context.read<AppState>().consumePendingRecordingNotice();
    if (notice != null && notice.isNotEmpty) {
      _showRecordingNotice(notice, showSnackBar: showSnackBar);
    }
  }

  Future<void> _start({bool preferBackend = false}) async {
    final appState = context.read<AppState>();

    try {
      if (Theme.of(context).platform == TargetPlatform.macOS) {
        if (preferBackend) {
          if (!appState.isBackendConnected) {
            _showRecordingNotice(
              'Backend is not connected yet. Wait for it to start, then retry.',
            );
            return;
          }
          final status = await appState.refreshBackendPermissionStatus(
            promptSystem: true,
            notify: false,
          );
          final screen = status?['screen_recording'];
          final granted = screen is Map && screen['granted'] == true;
          if (!granted) {
            await appState.openPermissionSettings('screen_recording');
            if (mounted) {
              _showRecordingNotice(appState.screenRecordingPermissionHint());
            }
            return;
          }
        } else if (!appState.hasScreenRecordingPermission) {
          await appState.promptScreenRecordingPermissionFlow();
          if (mounted) {
            _showRecordingNotice(appState.screenRecordingPermissionHint());
          }
          return;
        }
      }

      final mode = _screenIndex == null ? 'fullscreen' : 'fullscreen-single';
      await appState.startRecording(
        duration: appState.recordingDurationSec,
        interval: appState.recordingIntervalSec,
        mode: mode,
        screenIndex: _screenIndex,
        screenDisplayId: _screenDisplayId,
        preferBackend: preferBackend,
      );

      _consumePendingRecordingNotice(showSnackBar: true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showRecordingNotice(appState.describeRecordingStartError(e));
    }
  }

  Future<void> _stop() async {
    try {
      await context.read<AppState>().stopRecording();
      _stopPolling();
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showRecordingNotice('Failed to stop recording: $e');
    }
  }

  String _audioLabel(AppState appState) {
    switch (appState.recordingAudioSource) {
      case 'mixed':
        return 'System + Mic';
      case 'system_audio':
        return 'System only';
      case 'microphone':
        return 'Mic only';
      default:
        return 'Off';
    }
  }

  String _recordingEngineLabel(AppState appState) {
    if (Theme.of(context).platform == TargetPlatform.macOS &&
        appState.useNativeMacOSRecording) {
      if (appState.usingBackendRecordingFallback) {
        return 'Backend recorder (fallback)';
      }
      return 'Native macOS recorder';
    }
    return 'Backend recorder';
  }

  Widget _buildNoticeCard() {
    final notice = _recordingNotice;
    if (notice == null || notice.isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final (bg, fg, icon) = switch (_recordingNoticeLevel) {
      _RecordingNoticeLevel.error => (
          colorScheme.errorContainer,
          colorScheme.onErrorContainer,
          Icons.error_outline,
        ),
      _RecordingNoticeLevel.warning => (
          colorScheme.tertiaryContainer,
          colorScheme.onTertiaryContainer,
          Icons.warning_amber_outlined,
        ),
      _RecordingNoticeLevel.info => (
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurface,
          Icons.info_outline,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionHint(AppState appState) {
    if (Theme.of(context).platform != TargetPlatform.macOS ||
        appState.hasScreenRecordingPermission) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final permissionStatus = appState.permissionStatus;
    final runtimePath =
        (permissionStatus?['runtime_executable'] as String?)?.trim() ?? '';
    final appBundleHint =
        (permissionStatus?['app_bundle_hint'] as String?)?.trim() ?? '';
    final backendStatus = appState.backendPermissionStatus;
    final backendRuntimePath =
        (backendStatus?['runtime_executable'] as String?)?.trim() ?? '';
    final homePath = (Platform.environment['HOME'] ?? '').trim();
    final fallbackRuntimePath = homePath.isNotEmpty
        ? '$homePath/.memscreen/runtime/.venv/bin/python'
        : '';

    // Prefer backend python runtime first, because it is commonly the actual
    // screen-capture process in local/dev setups.
    final targets = <String>[];
    final effectiveRuntimePath = backendRuntimePath.isNotEmpty
        ? backendRuntimePath
        : fallbackRuntimePath;
    if (effectiveRuntimePath.isNotEmpty) {
      targets.add(effectiveRuntimePath);
    }
    final effectiveAppHint =
        appBundleHint.isNotEmpty ? appBundleHint : runtimePath;
    if (effectiveAppHint.isNotEmpty &&
        !targets.any((entry) => entry == effectiveAppHint)) {
      targets.add(effectiveAppHint);
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Screen Recording permission is required.',
            style: TextStyle(
              color: colorScheme.onErrorContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enable these entries in macOS Settings > Privacy & Security > Screen Recording:',
            style: TextStyle(color: colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 6),
          ...targets.asMap().entries.map((entry) {
            return Text(
              '${entry.key + 1}. ${entry.value}',
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontFamily: 'Menlo',
                fontSize: 12,
              ),
            );
          }),
          const SizedBox(height: 6),
          Text(
            'After granting access, completely quit and reopen MemScreen.',
            style: TextStyle(
              color: colorScheme.onErrorContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: appState.promptScreenRecordingPermissionFlow,
                icon: const Icon(Icons.security_outlined),
                label: const Text('Open Permission Flow'),
              ),
              if (appState.isBackendConnected)
                FilledButton.tonalIcon(
                  onPressed: () => _start(preferBackend: true),
                  icon: const Icon(Icons.cloud_sync_outlined),
                  label: const Text('Start via Backend'),
                ),
              FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('I Granted, Recheck'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatInterval(double seconds) {
    if (seconds % 1 == 0) {
      return '${seconds.toInt()}s';
    }
    return '${seconds.toStringAsFixed(1)}s';
  }

  Widget _statusChip({
    required IconData icon,
    required String label,
    required String value,
    Color? color,
    Color? textColor,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? scheme.surfaceContainerHighest;
    final fg = textColor ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(
            '$label · $value',
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickActions(AppState appState, bool isRecording) {
    final canUseBackendFallback = appState.isBackendConnected;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: isRecording ? null : _runSmokeCheck,
          icon: const Icon(Icons.health_and_safety_outlined),
          label: const Text('2s Smoke Check'),
        ),
        OutlinedButton.icon(
          onPressed: isRecording || !canUseBackendFallback
              ? null
              : _startBackendFallback,
          icon: const Icon(Icons.cloud_sync_outlined),
          label: const Text('Start via Backend'),
        ),
      ],
    );
  }

  Future<void> _runSmokeCheck() async {
    final appState = context.read<AppState>();
    try {
      final summary = await appState.runRecordingSmokeCheck(
        screenIndex: _screenIndex,
        screenDisplayId: _screenDisplayId,
      );
      if (!mounted) return;
      _showRecordingNotice(summary);
    } catch (e) {
      if (!mounted) return;
      _showRecordingNotice('Smoke check failed: $e');
    }
  }

  Future<void> _startBackendFallback() {
    return _start(preferBackend: true);
  }

  Future<void> _toggleFloatingBall(bool visible) async {
    final appState = context.read<AppState>();
    if (visible) {
      await appState.showFloatingBallController();
    } else {
      await appState.hideFloatingBallController();
    }
  }

  Future<void> _rebalanceFloatingBall() async {
    final appState = context.read<AppState>();
    await appState.rebalanceFloatingBallController();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Floating controller rebalanced')),
    );
  }

  String _formatTimestamp(DateTime? timestamp) {
    if (timestamp == null) {
      return 'never';
    }
    final local = timestamp.toLocal();
    final now = DateTime.now();
    final sameDay = local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
    final dayPart = sameDay ? 'Today' : '${local.month}/${local.day}';
    final timePart =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return '$dayPart $timePart';
  }

  String _capitalize(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value[0].toUpperCase() + value.substring(1);
  }

  Widget _buildFloatingBallCard(AppState appState) {
    if (!appState.supportsFloatingBallControls) {
      return const SizedBox.shrink();
    }
    final visible = appState.floatingBallPreferredVisible;
    final lastAction = appState.floatingBallLastCommand;
    final actionDescription = (lastAction ?? '').isEmpty
        ? null
        : '${_capitalize(lastAction!)} · ${_formatTimestamp(appState.floatingBallLastCommandAt)}';
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: visible ? scheme.primary : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                visible ? Icons.adjust : Icons.blur_circular,
                color: visible ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Floating Controller',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Switch(
                value: visible,
                onChanged: (value) => _toggleFloatingBall(value),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            visible
                ? 'Floating controls stay above other windows for quick start/stop.'
                : 'Floating controls are hidden. Use the switch to bring them back.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (actionDescription != null) ...[
            const SizedBox(height: 4),
            Text(
              'Last action: $actionDescription',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _rebalanceFloatingBall(),
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('Rebalance'),
              ),
              OutlinedButton.icon(
                onPressed: visible ? () => _toggleFloatingBall(false) : null,
                icon: const Icon(Icons.visibility_off),
                label: const Text('Hide'),
              ),
              OutlinedButton.icon(
                onPressed: visible ? null : () => _toggleFloatingBall(true),
                icon: const Icon(Icons.visibility),
                label: const Text('Show'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMainCard(AppState appState) {
    final isRecording = _status?.isRecording ?? false;
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = isRecording ? colorScheme.error : colorScheme.primary;
    final statusIcon =
        isRecording ? Icons.fiber_manual_record : Icons.play_circle_outline;
    final statusLabel = isRecording ? 'Recording now' : 'Ready to capture';
    final chips = <Widget>[
      _statusChip(
        icon: Icons.memory,
        label: 'Engine',
        value: _recordingEngineLabel(appState),
        color: appState.usingBackendRecordingFallback
            ? colorScheme.secondaryContainer
            : null,
        textColor: appState.usingBackendRecordingFallback
            ? colorScheme.onSecondaryContainer
            : null,
      ),
      _statusChip(
        icon: Icons.graphic_eq,
        label: 'Audio',
        value: _audioLabel(appState),
      ),
      if (_showAdvanced)
        _statusChip(
          icon: Icons.schedule,
          label: 'Duration',
          value: '${appState.recordingDurationSec}s',
        ),
      if (_showAdvanced)
        _statusChip(
          icon: Icons.timelapse,
          label: 'Interval',
          value: _formatInterval(appState.recordingIntervalSec),
        ),
      if (_showAdvanced && appState.autoTrackInputWithRecording)
        _statusChip(
          icon: Icons.monitor_heart,
          label: 'Tracking',
          value: 'Auto',
        ),
    ];
    final shouldShowPermissionHint =
        Theme.of(context).platform == TargetPlatform.macOS &&
            !appState.hasScreenRecordingPermission;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: statusColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Screen Recording',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                statusLabel,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips,
          ),
          const SizedBox(height: 12),
          if (shouldShowPermissionHint) ...[
            _buildPermissionHint(appState),
            const SizedBox(height: 12),
          ],
          DropdownButtonFormField<int>(
            key: ValueKey(_screenIndex ?? -1),
            initialValue: _screenIndex ?? -1,
            decoration: const InputDecoration(
              labelText: 'Display target',
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: [
              const DropdownMenuItem<int>(
                value: -1,
                child: Text('All Screens'),
              ),
              ..._screens.map(
                (screen) => DropdownMenuItem<int>(
                  value: screen.index,
                  child: Text(
                    '${screen.name} (${screen.width}x${screen.height})${screen.isPrimary ? " [Primary]" : ""}',
                  ),
                ),
              ),
            ],
            onChanged: isRecording
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _screenIndex = value < 0 ? null : value;
                      final selected = _resolveSelectedScreen(_screens);
                      _screenDisplayId = selected?.displayId;
                    });
                  },
          ),
          const SizedBox(height: 12),
          if (isRecording)
            FilledButton.icon(
              onPressed: _stop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop Recording'),
              style: FilledButton.styleFrom(
                backgroundColor: colorScheme.error,
              ),
            )
          else
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('Start Recording'),
            ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(
                _showAdvanced ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_showAdvanced ? 'Hide advanced' : 'Show advanced'),
            ),
          ),
          if (_showAdvanced) ...[
            const SizedBox(height: 8),
            _buildQuickActions(appState, isRecording),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _status == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final appState = context.watch<AppState>();
    final showFloatingBallCard =
        appState.supportsFloatingBallControls && _showAdvanced;
    final hasNotice = (_recordingNotice ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildMainCard(appState),
                    if (showFloatingBallCard) ...[
                      const SizedBox(height: 12),
                      _buildFloatingBallCard(appState),
                    ],
                    if (hasNotice) ...[
                      const SizedBox(height: 12),
                      _buildNoticeCard(),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
