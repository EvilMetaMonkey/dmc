import 'dart:async';

import 'package:dart_console/dart_console.dart';

import 'database.dart';
import 'diff.dart';
import 'log.dart';
import 'restore.dart';
import 'version.dart';
import 'workspace.dart';

const int _defaultHistoryLimit = 25;
final RegExp _ansiPattern = RegExp(r'\x1B\[[0-9;]*m');
const String _ansiEnterAlternateScreen = '\x1B[?1049h';
const String _ansiExitAlternateScreen = '\x1B[?1049l';

enum DmcUiView { splash, dashboard }

enum DmcUiInput {
  up,
  down,
  left,
  right,
  enter,
  back,
  quit,
  restore,
  actionStartDaemon,
  actionStatusVaults,
  actionViewHistory,
  actionLaunchDashboard,
  actionFastRestore,
  actionConfigure,
}

enum DmcUiMenuAction {
  startDaemon,
  statusVaults,
  viewHistory,
  launchDashboard,
  fastRestore,
  configure,
  quit,
}

class DmcUiMenuItem {
  final String keyLabel;
  final String label;
  final DmcUiMenuAction action;
  final int column;
  final int row;
  const DmcUiMenuItem(
    this.keyLabel,
    this.label,
    this.action,
    this.column,
    this.row,
  );
}

const _menuItems = <DmcUiMenuItem>[
  DmcUiMenuItem('S', 'Start dmc Daemon', DmcUiMenuAction.startDaemon, 0, 0),
  DmcUiMenuItem(
    'T',
    'Status / Active Vaults',
    DmcUiMenuAction.statusVaults,
    0,
    1,
  ),
  DmcUiMenuItem('L', 'View History Log', DmcUiMenuAction.viewHistory, 0, 2),
  DmcUiMenuItem(
    'U',
    'Launch Interactive UI (TUI)',
    DmcUiMenuAction.launchDashboard,
    0,
    3,
  ),
  DmcUiMenuItem(
    'R',
    'Fast Restore (Last 5 Mins)',
    DmcUiMenuAction.fastRestore,
    1,
    0,
  ),
  DmcUiMenuItem('C', 'Configure Settings', DmcUiMenuAction.configure, 1, 1),
  DmcUiMenuItem('Q', 'Quit', DmcUiMenuAction.quit, 1, 2),
];

class DmcUiHistoryEntry {
  final int snapshotId;
  final String filePath;
  final String snapshotPath;
  final int timestamp;
  final int? burstId;
  const DmcUiHistoryEntry({
    required this.snapshotId,
    required this.filePath,
    required this.snapshotPath,
    required this.timestamp,
    required this.burstId,
  });
}

class DmcUiDashboardLayout {
  final int panelTop;
  final int panelHeight;
  final int leftCol;
  final int leftWidth;
  final int rightCol;
  final int rightWidth;
  final int statusRow;
  final int commandRow;

  const DmcUiDashboardLayout({
    required this.panelTop,
    required this.panelHeight,
    required this.leftCol,
    required this.leftWidth,
    required this.rightCol,
    required this.rightWidth,
    required this.statusRow,
    required this.commandRow,
  });
}

DmcUiDashboardLayout computeDashboardLayout({
  required int width,
  required int height,
}) {
  final totalPanelWidth = width - 4;
  var leftWidth = width < 110
      ? totalPanelWidth ~/ 2
      : (totalPanelWidth * 42 ~/ 100);
  final minLeftWidth = totalPanelWidth >= 54 ? 26 : totalPanelWidth ~/ 2;
  final maxLeftWidth = totalPanelWidth >= 54
      ? totalPanelWidth - 28
      : totalPanelWidth - minLeftWidth;
  leftWidth = leftWidth.clamp(minLeftWidth, maxLeftWidth);
  final rightWidth = totalPanelWidth - leftWidth;
  final panelTop = 5;
  final commandRow = (height - 3).clamp(panelTop + 8, height - 2);
  final statusRow = commandRow - 2;
  final panelHeight = (statusRow - panelTop).clamp(10, height);

  return DmcUiDashboardLayout(
    panelTop: panelTop,
    panelHeight: panelHeight,
    leftCol: 1,
    leftWidth: leftWidth,
    rightCol: leftWidth + 3,
    rightWidth: rightWidth,
    statusRow: statusRow,
    commandRow: commandRow,
  );
}

int computeCenteredColumn({
  required int width,
  required String text,
  int horizontalPadding = 2,
}) {
  if (width <= 0) {
    return 0;
  }
  final visible = _truncate(_singleLine(text), width - horizontalPadding);
  if (visible.isEmpty) {
    return 0;
  }
  return ((width - visible.length) ~/ 2).clamp(0, width - 1);
}

class DmcUiState {
  final DmcUiView view;
  final List<DmcUiHistoryEntry> entries;
  final int selectedIndex;
  final int splashSelectedIndex;
  final String? statusMessage;

  const DmcUiState({
    required this.view,
    required this.entries,
    required this.selectedIndex,
    required this.splashSelectedIndex,
    this.statusMessage,
  });

  factory DmcUiState.initial(List<DmcUiHistoryEntry> entries) => DmcUiState(
    view: DmcUiView.splash,
    entries: entries,
    selectedIndex: 0,
    splashSelectedIndex: 0,
  );

  DmcUiHistoryEntry? get selectedEntry => entries.isEmpty
      ? null
      : entries[selectedIndex.clamp(0, entries.length - 1)];
  DmcUiMenuItem get selectedMenuItem =>
      _menuItems[splashSelectedIndex.clamp(0, _menuItems.length - 1)];

  DmcUiState copyWith({
    DmcUiView? view,
    List<DmcUiHistoryEntry>? entries,
    int? selectedIndex,
    int? splashSelectedIndex,
    String? statusMessage,
    bool clearStatusMessage = false,
  }) {
    final nextEntries = entries ?? this.entries;
    final nextSelectedIndex = nextEntries.isEmpty
        ? 0
        : (selectedIndex ?? this.selectedIndex).clamp(
            0,
            nextEntries.length - 1,
          );
    return DmcUiState(
      view: view ?? this.view,
      entries: nextEntries,
      selectedIndex: nextSelectedIndex,
      splashSelectedIndex: (splashSelectedIndex ?? this.splashSelectedIndex)
          .clamp(0, _menuItems.length - 1),
      statusMessage: clearStatusMessage
          ? null
          : statusMessage ?? this.statusMessage,
    );
  }
}

class DmcUiTransition {
  final DmcUiState state;
  final bool shouldExit;
  final bool shouldRestore;
  const DmcUiTransition({
    required this.state,
    this.shouldExit = false,
    this.shouldRestore = false,
  });
}

class DmcUiController {
  DmcUiState _state;
  DmcUiController(List<DmcUiHistoryEntry> entries)
    : _state = DmcUiState.initial(entries);
  DmcUiState get state => _state;

  DmcUiTransition handleInput(DmcUiInput input) =>
      _state.view == DmcUiView.splash
      ? _handleSplash(input)
      : _handleDashboard(input);

  void setStatusMessage(String? message) {
    _state = _state.copyWith(
      statusMessage: message,
      clearStatusMessage: message == null,
    );
  }

  void replaceEntries(
    List<DmcUiHistoryEntry> entries, {
    int? preferredSnapshotId,
  }) {
    var index = 0;
    if (preferredSnapshotId != null) {
      final found = entries.indexWhere(
        (entry) => entry.snapshotId == preferredSnapshotId,
      );
      if (found >= 0) index = found;
    }
    _state = _state.copyWith(entries: entries, selectedIndex: index);
  }

  DmcUiTransition _handleSplash(DmcUiInput input) {
    final curIndex = _state.splashSelectedIndex;
    final curItem = _menuItems[curIndex];

    switch (input) {
      case DmcUiInput.up:
        int nextIndex;
        if (curItem.column == 0) {
          final nextRow = (curItem.row - 1 + 4) % 4;
          nextIndex = _menuItems.indexWhere(
            (it) => it.column == 0 && it.row == nextRow,
          );
        } else {
          final nextRow = (curItem.row - 1 + 3) % 3;
          nextIndex = _menuItems.indexWhere(
            (it) => it.column == 1 && it.row == nextRow,
          );
        }
        if (nextIndex < 0) {
          nextIndex = (curIndex - 1 + _menuItems.length) % _menuItems.length;
        }
        _state = _state.copyWith(
          splashSelectedIndex: nextIndex,
          clearStatusMessage: true,
        );
        return DmcUiTransition(state: _state);

      case DmcUiInput.down:
        int nextIndex;
        if (curItem.column == 0) {
          final nextRow = (curItem.row + 1) % 4;
          nextIndex = _menuItems.indexWhere(
            (it) => it.column == 0 && it.row == nextRow,
          );
        } else {
          final nextRow = (curItem.row + 1) % 3;
          nextIndex = _menuItems.indexWhere(
            (it) => it.column == 1 && it.row == nextRow,
          );
        }
        if (nextIndex < 0) {
          nextIndex = (curIndex + 1) % _menuItems.length;
        }
        _state = _state.copyWith(
          splashSelectedIndex: nextIndex,
          clearStatusMessage: true,
        );
        return DmcUiTransition(state: _state);

      case DmcUiInput.left:
        if (curItem.column == 1) {
          final targetRow = curItem.row.clamp(0, 3);
          final nextIndex = _menuItems.indexWhere(
            (it) => it.column == 0 && it.row == targetRow,
          );
          if (nextIndex >= 0) {
            _state = _state.copyWith(
              splashSelectedIndex: nextIndex,
              clearStatusMessage: true,
            );
          }
        }
        return DmcUiTransition(state: _state);

      case DmcUiInput.right:
        if (curItem.column == 0) {
          final targetRow = curItem.row.clamp(0, 2);
          final nextIndex = _menuItems.indexWhere(
            (it) => it.column == 1 && it.row == targetRow,
          );
          if (nextIndex >= 0) {
            _state = _state.copyWith(
              splashSelectedIndex: nextIndex,
              clearStatusMessage: true,
            );
          }
        }
        return DmcUiTransition(state: _state);

      case DmcUiInput.enter:
        return _executeSplashAction(_state.selectedMenuItem.action);

      case DmcUiInput.actionStartDaemon:
        _state = _state.copyWith(splashSelectedIndex: 0);
        return _executeSplashAction(DmcUiMenuAction.startDaemon);

      case DmcUiInput.actionStatusVaults:
        _state = _state.copyWith(splashSelectedIndex: 1);
        return _executeSplashAction(DmcUiMenuAction.statusVaults);

      case DmcUiInput.actionViewHistory:
        _state = _state.copyWith(splashSelectedIndex: 2);
        return _executeSplashAction(DmcUiMenuAction.viewHistory);

      case DmcUiInput.actionLaunchDashboard:
        _state = _state.copyWith(splashSelectedIndex: 3);
        return _executeSplashAction(DmcUiMenuAction.launchDashboard);

      case DmcUiInput.restore:
      case DmcUiInput.actionFastRestore:
        _state = _state.copyWith(splashSelectedIndex: 4);
        return _executeSplashAction(DmcUiMenuAction.fastRestore);

      case DmcUiInput.actionConfigure:
        _state = _state.copyWith(splashSelectedIndex: 5);
        return _executeSplashAction(DmcUiMenuAction.configure);

      case DmcUiInput.quit:
        return DmcUiTransition(state: _state, shouldExit: true);

      default:
        return DmcUiTransition(state: _state);
    }
  }

  DmcUiTransition _executeSplashAction(DmcUiMenuAction action) {
    if (action == DmcUiMenuAction.launchDashboard ||
        action == DmcUiMenuAction.viewHistory) {
      _state = _state.copyWith(
        view: DmcUiView.dashboard,
        clearStatusMessage: true,
      );
      return DmcUiTransition(state: _state);
    }
    if (action == DmcUiMenuAction.quit) {
      return DmcUiTransition(state: _state, shouldExit: true);
    }
    _state = _state.copyWith(
      statusMessage: _splashActionMessage(action),
    );
    return DmcUiTransition(state: _state);
  }

  DmcUiTransition _handleDashboard(DmcUiInput input) {
    final maxIndex = _state.entries.isEmpty ? 0 : _state.entries.length - 1;
    switch (input) {
      case DmcUiInput.up:
        _state = _state.copyWith(
          selectedIndex: (_state.selectedIndex - 1).clamp(0, maxIndex),
          clearStatusMessage: true,
        );
        return DmcUiTransition(state: _state);
      case DmcUiInput.down:
        _state = _state.copyWith(
          selectedIndex: (_state.selectedIndex + 1).clamp(0, maxIndex),
          clearStatusMessage: true,
        );
        return DmcUiTransition(state: _state);
      case DmcUiInput.enter:
        final entry = _state.selectedEntry;
        _state = _state.copyWith(
          statusMessage: entry == null
              ? 'No snapshot selected.'
              : 'Selected snapshot ${entry.snapshotId} for ${entry.filePath}',
        );
        return DmcUiTransition(state: _state);
      case DmcUiInput.back:
        _state = _state.copyWith(
          view: DmcUiView.splash,
          clearStatusMessage: true,
        );
        return DmcUiTransition(state: _state);
      case DmcUiInput.restore:
        return DmcUiTransition(state: _state, shouldRestore: true);
      case DmcUiInput.quit:
        return DmcUiTransition(state: _state, shouldExit: true);
      default:
        return DmcUiTransition(state: _state);
    }
  }
}

String _splashActionMessage(DmcUiMenuAction action) {
  switch (action) {
    case DmcUiMenuAction.startDaemon:
      return 'Exit UI and run `dmc start` to launch the watcher daemon.';
    case DmcUiMenuAction.statusVaults:
      return 'Exit UI and run `dmc status` or `dmc doctor` for vault health.';
    case DmcUiMenuAction.fastRestore:
      return 'Open history, select a snapshot, and press R to restore safely.';
    case DmcUiMenuAction.configure:
      return 'Edit .dmc/config.json or ~/.dmcconfig, then restart the watcher.';
    case DmcUiMenuAction.viewHistory:
    case DmcUiMenuAction.launchDashboard:
      return 'Opening history.';
    case DmcUiMenuAction.quit:
      return 'Quit.';
  }
}

Future<int> runInteractiveUi({
  String? basePath,
  int limit = _defaultHistoryLimit,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final console = Console();
  if (!console.hasTerminal) {
    console.writeLine(
      '[DMC] Your current terminal does not support interactive UI mode.',
    );
    return 1;
  }
  if (!await paths.dmcDirectory.exists()) {
    console.writeLine(
      '[DMC] Error: DMC not initialized. Run "dmc init" first.',
    );
    return 1;
  }
  final entries = await loadUiHistoryEntries(
    basePath: paths.rootPath,
    limit: limit,
  );
  if (entries.isEmpty) {
    console.writeLine('[DMC] No backup history found.');
    return 1;
  }
  final controller = DmcUiController(entries);
  var usingAlternateScreen = false;
  var exitCode = 0;
  String? fatalErrorMessage;
  try {
    console.write(_ansiEnterAlternateScreen);
    usingAlternateScreen = true;
    console.clearScreen();
    console.resetCursorPosition();
    console.resetColorAttributes();
    console.hideCursor();
    while (true) {
      await _renderUiFrame(
        console,
        controller.state,
        basePath: paths.rootPath,
        historyLimit: limit,
      );
      final input = _mapKey(console.readKey());
      if (input == null) continue;
      final transition = controller.handleInput(input);
      if (transition.shouldRestore) {
        final entry = controller.state.selectedEntry;
        if (entry != null) {
          controller.setStatusMessage(
            await _restoreSelectedEntry(entry, basePath: paths.rootPath),
          );
          controller.replaceEntries(
            await loadUiHistoryEntries(basePath: paths.rootPath, limit: limit),
            preferredSnapshotId: entry.snapshotId,
          );
        }
      }
      if (transition.shouldExit) break;
    }
  } catch (e) {
    exitCode = 1;
    fatalErrorMessage = '[DMC] Error running interactive UI: $e';
  } finally {
    console.resetColorAttributes();
    console.showCursor();
    console.clearScreen();
    console.resetCursorPosition();
    if (usingAlternateScreen) {
      console.write(_ansiExitAlternateScreen);
    }
  }
  if (fatalErrorMessage != null) {
    console.writeLine(fatalErrorMessage);
  }
  return exitCode;
}

Future<List<DmcUiHistoryEntry>> loadUiHistoryEntries({
  String? basePath,
  int limit = _defaultHistoryLimit,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final db = DmcDatabase(paths.dbPath);
  db.initialize();
  final history = db.getRecentHistory(limit: limit);
  db.close();
  return history
      .map(
        (entry) => DmcUiHistoryEntry(
          snapshotId: entry.id,
          filePath: entry.filePath,
          snapshotPath: entry.snapshotPath,
          timestamp: entry.timestamp,
          burstId: entry.burstId,
        ),
      )
      .toList();
}

DmcUiInput? _mapKey(Key key) {
  if (key.isControl) {
    switch (key.controlChar) {
      case ControlCharacter.arrowUp:
        return DmcUiInput.up;
      case ControlCharacter.arrowDown:
        return DmcUiInput.down;
      case ControlCharacter.arrowLeft:
        return DmcUiInput.left;
      case ControlCharacter.arrowRight:
        return DmcUiInput.right;
      case ControlCharacter.enter:
        return DmcUiInput.enter;
      case ControlCharacter.escape:
        return DmcUiInput.back;
      default:
        return null;
    }
  }
  switch (key.char.toLowerCase()) {
    case 'q':
      return DmcUiInput.quit;
    case 'r':
      return DmcUiInput.restore;
    case 's':
      return DmcUiInput.actionStartDaemon;
    case 't':
      return DmcUiInput.actionStatusVaults;
    case 'l':
      return DmcUiInput.actionViewHistory;
    case 'u':
      return DmcUiInput.actionLaunchDashboard;
    case 'c':
      return DmcUiInput.actionConfigure;
    default:
      return null;
  }
}

Future<String> _restoreSelectedEntry(
  DmcUiHistoryEntry entry, {
  required String basePath,
}) async {
  final lines = <String>[];
  late RestoreResult result;
  await runZoned(
    () async => result = await undoFile(
      entry.filePath,
      id: entry.snapshotId,
      basePath: basePath,
    ),
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, String line) => lines.add(line),
    ),
  );
  return result.hadError
      ? (lines.isNotEmpty
            ? lines.last
            : 'Restore failed for ${entry.filePath}.')
      : 'Restored ${entry.filePath} from snapshot ${entry.snapshotId}.';
}

Future<void> _renderUiFrame(
  Console console,
  DmcUiState state, {
  required String basePath,
  required int historyLimit,
}) async {
  console.clearScreen();
  console.resetCursorPosition();
  console.resetColorAttributes();
  if (state.view == DmcUiView.splash) {
    _renderSplash(console, state);
  } else {
    await _renderDashboard(
      console,
      state,
      basePath: basePath,
      historyLimit: historyLimit,
    );
  }
}

void _renderSplash(Console console, DmcUiState state) {
  final width = console.windowWidth;
  final height = console.windowHeight;
  final compact = width < 110 || height < 36;

  // ── Header ──────────────────────────────────────────────────────────
  final headerText = 'DMC $dmcVersion (DE LOREAN MOTOR COMPANY)';
  final headerCol = ((width - headerText.length) ~/ 2).clamp(2, width - 2);
  _at(console, 1, 2, '─' * (headerCol - 3), fg: ConsoleColor.brightBlack);
  _at(console, 1, headerCol, headerText, fg: ConsoleColor.yellow);
  final rightRuleStart = headerCol + headerText.length + 1;
  final rightRuleLen = (width - rightRuleStart - 2).clamp(0, width);
  if (rightRuleLen > 0) {
    _at(
      console,
      1,
      rightRuleStart,
      '─' * rightRuleLen,
      fg: ConsoleColor.brightBlack,
    );
  }

  final carTop = compact ? 2 : 3;
  final deloreanArt = buildSplashDeloreanArt();
  for (var i = 0; i < deloreanArt.length; i++) {
    _writeCenteredLine(
      console,
      carTop + i,
      deloreanArt[i],
      fg: ConsoleColor.white,
    );
  }

  final statusRow = carTop + deloreanArt.length + 1;
  _statusRow(console, statusRow, width, compact: compact);
  _menu(console, state, statusRow + 2, width, compact: compact);

  // ── Footer ──────────────────────────────────────────────────────────
  _center(
    console,
    height - 2,
    '[UP]/[DOWN] Navigation | [ENTER] Select | [ESC] Previous | [?] Help | TUI Build Phase 14.1',
    ConsoleColor.brightBlack,
    maxWidth: width - 8,
  );
}

Future<void> _renderDashboard(
  Console console,
  DmcUiState state, {
  required String basePath,
  required int historyLimit,
}) async {
  final width = console.windowWidth;
  final height = console.windowHeight;
  final layout = computeDashboardLayout(width: width, height: height);

  _frame(console, 0, 0, width, height, outer: true);
  _header(console, width, basePath, state.entries.length);
  _panel(
    console,
    layout.panelTop,
    layout.leftCol,
    layout.leftWidth,
    layout.panelHeight,
  );
  _panel(
    console,
    layout.panelTop,
    layout.rightCol,
    layout.rightWidth,
    layout.panelHeight,
  );
  _history(
    console,
    state,
    layout.panelTop + 1,
    layout.leftCol + 1,
    layout.leftWidth - 2,
    layout.panelHeight - 2,
  );
  await _diff(
    console,
    state,
    layout.panelTop + 1,
    layout.rightCol + 1,
    layout.rightWidth - 2,
    layout.panelHeight - 2,
    basePath,
  );
  _dashboardStatusLine(console, layout.statusRow, width, state, historyLimit);
  _dashboardCommandBar(console, layout.commandRow, width);
}

void _dashboardStatusLine(
  Console console,
  int row,
  int width,
  DmcUiState state,
  int historyLimit,
) {
  final selected = state.selectedEntry;
  _rule(console, row - 1, width, ConsoleColor.cyan);
  _at(
    console,
    row,
    1,
    ' ' * (width - 2),
    bg: ConsoleColor.brightBlack,
    maxWidth: width - 2,
  );
  _at(
    console,
    row,
    2,
    _fit(
      'VAULT: ${state.entries.length}/$historyLimit recent snapshots loaded',
      (width - 38).clamp(18, width - 4),
    ),
    fg: ConsoleColor.white,
    bg: ConsoleColor.brightBlack,
    maxWidth: (width - 38).clamp(18, width - 4),
  );
  final selection = selected == null
      ? 'SELECTED: none'
      : 'SELECTED: #${selected.snapshotId} / ${selected.burstId == null ? 'snapshot' : 'burst ${selected.burstId}'}';
  final selectionText = _truncate(selection, (width ~/ 2).clamp(16, width - 4));
  _at(
    console,
    row,
    (width - selectionText.length - 2).clamp(2, width - 2),
    selectionText,
    fg: ConsoleColor.green,
    bg: ConsoleColor.brightBlack,
    maxWidth: width - 4,
  );
}

void _dashboardCommandBar(Console console, int row, int width) {
  final compact = width < 96;
  _rule(console, row - 1, width, ConsoleColor.cyan);
  _at(
    console,
    row,
    1,
    ' ' * (width - 2),
    bg: ConsoleColor.brightBlack,
    maxWidth: width - 2,
  );
  if (compact) {
    _at(
      console,
      row,
      2,
      '[UP/DOWN]',
      fg: ConsoleColor.black,
      bg: ConsoleColor.white,
    );
    _at(
      console,
      row,
      13,
      'Nav',
      fg: ConsoleColor.white,
      bg: ConsoleColor.brightBlack,
    );
    _at(
      console,
      row,
      18,
      '[R]',
      fg: ConsoleColor.black,
      bg: ConsoleColor.yellow,
    );
    _at(
      console,
      row,
      22,
      'Restore',
      fg: ConsoleColor.yellow,
      bg: ConsoleColor.brightBlack,
    );
    _at(
      console,
      row,
      width - 18,
      '[ESC]',
      fg: ConsoleColor.black,
      bg: ConsoleColor.white,
    );
    _at(
      console,
      row,
      width - 11,
      'Back',
      fg: ConsoleColor.white,
      bg: ConsoleColor.brightBlack,
    );
    _at(
      console,
      row,
      width - 5,
      '[Q]',
      fg: ConsoleColor.black,
      bg: ConsoleColor.yellow,
    );
    return;
  }

  _at(
    console,
    row,
    2,
    '[UP/DOWN]',
    fg: ConsoleColor.black,
    bg: ConsoleColor.white,
  );
  _at(
    console,
    row,
    13,
    'Navigate',
    fg: ConsoleColor.white,
    bg: ConsoleColor.brightBlack,
  );
  _at(
    console,
    row,
    25,
    '[ENTER]',
    fg: ConsoleColor.black,
    bg: ConsoleColor.white,
  );
  _at(
    console,
    row,
    34,
    'Pin Snapshot',
    fg: ConsoleColor.white,
    bg: ConsoleColor.brightBlack,
  );
  _at(console, row, 49, '[R]', fg: ConsoleColor.black, bg: ConsoleColor.yellow);
  _at(
    console,
    row,
    53,
    'Restore',
    fg: ConsoleColor.yellow,
    bg: ConsoleColor.brightBlack,
  );
  _at(
    console,
    row,
    width - 24,
    '[ESC]',
    fg: ConsoleColor.black,
    bg: ConsoleColor.white,
  );
  _at(
    console,
    row,
    width - 17,
    'Previous',
    fg: ConsoleColor.white,
    bg: ConsoleColor.brightBlack,
  );
  _at(
    console,
    row,
    width - 7,
    '[Q]',
    fg: ConsoleColor.black,
    bg: ConsoleColor.yellow,
  );
}

void _header(Console console, int width, String basePath, int count) {
  final compact = width < 96;
  _at(
    console,
    1,
    1,
    ' ' * (width - 2),
    bg: ConsoleColor.brightBlack,
    maxWidth: width - 2,
  );
  _at(
    console,
    1,
    2,
    'DMC $dmcVersion',
    fg: ConsoleColor.yellow,
    bg: ConsoleColor.brightBlack,
  );
  _center(
    console,
    1,
    compact ? 'dmc - Dashboard' : 'dmc - DeLorean Dashboard',
    ConsoleColor.brightWhite,
    maxWidth: width - 8,
  );
  _at(
    console,
    1,
    (width - 21).clamp(2, width - 2),
    'DAEMON:',
    fg: ConsoleColor.yellow,
    bg: ConsoleColor.brightBlack,
  );
  _at(
    console,
    1,
    (width - 13).clamp(2, width - 2),
    'ACTIVE',
    fg: ConsoleColor.green,
    bg: ConsoleColor.brightBlack,
  );
  _at(
    console,
    2,
    2,
    _fit(
      '/${_truncate(basePath, compact ? width - 22 : width - 26)}',
      compact ? width - 24 : width - 28,
    ),
    fg: ConsoleColor.brightCyan,
    maxWidth: compact ? width - 24 : width - 28,
  );
  _at(
    console,
    2,
    compact ? width - 18 : width - 22,
    'VAULT:',
    fg: ConsoleColor.yellow,
  );
  _at(
    console,
    2,
    compact ? width - 11 : width - 15,
    '$count',
    fg: ConsoleColor.white,
  );
  _at(
    console,
    2,
    compact ? width - 8 : width - 12,
    'LIVE',
    fg: ConsoleColor.green,
  );
  _rule(console, 3, width, ConsoleColor.cyan);
}

void _history(
  Console console,
  DmcUiState state,
  int row,
  int col,
  int width,
  int height,
) {
  final items = state.entries.take((height - 5).clamp(0, height)).toList();
  _sectionTitleBar(
    console,
    row,
    col,
    width,
    'BURST HISTORY',
    rightText: 'Latest ${items.length}',
  );
  _at(
    console,
    row + 1,
    col + 2,
    _fit('Recent vault timeline / newest snapshots first', width - 4),
    fg: ConsoleColor.brightBlack,
    maxWidth: width - 4,
  );
  _panelRule(console, row + 2, col, width, ConsoleColor.cyan);
  for (var i = 0; i < items.length; i++) {
    final entry = items[i];
    final selected = i == state.selectedIndex;
    final lineRow = row + 3 + i;
    final timestamp = formatTimestamp(entry.timestamp).substring(11, 16);
    final burstLabel = entry.burstId == null
        ? 'Snapshot'
        : 'Burst #${entry.burstId}';
    final snapshotLabel = '#${entry.snapshotId}';
    final fileWidth = (width - snapshotLabel.length - 31).clamp(4, width);

    _at(
      console,
      lineRow,
      col,
      ' ' * width,
      bg: selected ? ConsoleColor.brightBlack : null,
      maxWidth: width,
    );
    _at(
      console,
      lineRow,
      col,
      selected ? '▌' : '│',
      fg: selected ? ConsoleColor.yellow : ConsoleColor.cyan,
    );
    _at(
      console,
      lineRow,
      col + 2,
      timestamp,
      fg: selected ? ConsoleColor.yellow : ConsoleColor.brightWhite,
      bg: selected ? ConsoleColor.brightBlack : null,
    );
    _at(
      console,
      lineRow,
      col + 9,
      '|',
      fg: ConsoleColor.cyan,
      bg: selected ? ConsoleColor.brightBlack : null,
    );
    _at(
      console,
      lineRow,
      col + 12,
      _truncate(burstLabel, 11).padRight(11),
      fg: selected ? ConsoleColor.brightWhite : ConsoleColor.white,
      bg: selected ? ConsoleColor.brightBlack : null,
      maxWidth: 11,
    );
    _at(
      console,
      lineRow,
      col + 24,
      '|',
      fg: ConsoleColor.cyan,
      bg: selected ? ConsoleColor.brightBlack : null,
    );
    _at(
      console,
      lineRow,
      col + 27,
      _truncate(entry.filePath, fileWidth),
      fg: selected ? ConsoleColor.brightWhite : ConsoleColor.white,
      bg: selected ? ConsoleColor.brightBlack : null,
      maxWidth: fileWidth,
    );
    _at(
      console,
      lineRow,
      col + width - snapshotLabel.length - 2,
      snapshotLabel,
      fg: selected ? ConsoleColor.yellow : ConsoleColor.brightCyan,
      bg: selected ? ConsoleColor.brightBlack : null,
      maxWidth: snapshotLabel.length,
    );
  }
  _at(
    console,
    row + height - 2,
    col,
    _fit(
      state.statusMessage ??
          'Live diff preview is pinned to the highlighted timeline entry.',
      width,
    ),
    fg: ConsoleColor.brightWhite,
    bg: ConsoleColor.brightBlack,
    maxWidth: width,
  );
}

Future<void> _diff(
  Console console,
  DmcUiState state,
  int row,
  int col,
  int width,
  int height,
  String basePath,
) async {
  final entry = state.selectedEntry;
  _sectionTitleBar(
    console,
    row,
    col,
    width,
    'FLUX CAPACITOR - DIFF VIEW',
    rightText: 'Live Preview',
  );
  if (entry == null) {
    _at(
      console,
      row + 2,
      col + 2,
      'No snapshot selected.',
      fg: ConsoleColor.brightRed,
      maxWidth: width - 4,
    );
    return;
  }
  _at(
    console,
    row + 1,
    col + 2,
    _fit('/${entry.filePath}', width - 20),
    fg: ConsoleColor.brightCyan,
    maxWidth: width - 20,
  );
  final snapshotText = '[SNAPSHOT ${entry.snapshotId}]';
  _at(
    console,
    row + 1,
    col + width - snapshotText.length - 2,
    snapshotText,
    fg: ConsoleColor.yellow,
    maxWidth: snapshotText.length,
  );
  _at(
    console,
    row + 2,
    col + 2,
    _fit(
      'Burst: ${entry.burstId ?? 'legacy'} | Time: ${formatTimestamp(entry.timestamp)}',
      width - 4,
    ),
    fg: ConsoleColor.yellow,
    maxWidth: width - 4,
  );
  final lines =
      (await buildDiffOutput(
        entry.filePath,
        id: entry.snapshotId,
        basePath: basePath,
      )).output?.split('\n') ??
      const ['[DMC] No diff available.'];
  _panelRule(console, row + 3, col, width, ConsoleColor.cyan);
  for (var i = 0; i < height - 5 && i < lines.length; i++) {
    _at(
      console,
      row + 4 + i,
      col + 1,
      _truncateAnsi(lines[i], width - 2),
      maxWidth: width - 2,
    );
  }
}

void _menu(
  Console console,
  DmcUiState state,
  int top,
  int width, {
  required bool compact,
}) {
  // Always render a 2-column grid when width >= 80, regardless of height.
  // In very narrow terminals, fall back to a single-column stack.
  final useColumns = width >= 80;
  final colPad = 34; // label field width per column
  final leftCol = useColumns
      ? ((width ~/ 2) - colPad - 3).clamp(4, width ~/ 2)
      : 6;
  final rightCol = useColumns ? (width ~/ 2) + 2 : 6;

  for (var i = 0; i < _menuItems.length; i++) {
    final item = _menuItems[i];
    final selected = i == state.splashSelectedIndex;

    int row;
    int col;
    if (useColumns) {
      // 2-column: column 0 => left, column 1 => right, same row offset
      row = top + item.row;
      col = item.column == 0 ? leftCol : rightCol;
    } else {
      // single-column stack: column 1 items go below column 0 items
      row = item.column == 1 ? top + 5 + item.row : top + item.row;
      col = leftCol;
    }

    // Hotkey badge: [S], [T], etc.
    _at(
      console,
      row,
      col,
      '[${item.keyLabel}]',
      fg: ConsoleColor.black,
      bg: ConsoleColor.yellow,
    );
    // Label with exact padding to enforce column alignment
    final labelWidth = useColumns ? colPad : (width - col - 8).clamp(16, 50);
    _at(
      console,
      row,
      col + 4,
      _fit(' > ${item.label}', labelWidth),
      fg: selected ? ConsoleColor.yellow : ConsoleColor.white,
    );
  }

  // Status message (for safe action guidance and restore feedback)
  final msgRow = useColumns ? top + 5 : top + 9;
  if (state.statusMessage != null) {
    _center(
      console,
      msgRow,
      state.statusMessage!,
      ConsoleColor.yellow,
      maxWidth: width - 12,
    );
  }
}

void _statusRow(Console console, int row, int width, {required bool compact}) {
  final vault = compact ? 'flux-capacitor' : 'flux-capacitor v0.9 (980MB)';
  final text = 'SYSTEM: ONLINE | VAULT: $vault | HOUSTON-WS-1';
  final col = ((width - text.length) ~/ 2).clamp(4, width - 4);
  _at(console, row, 4, '─' * (col - 6), fg: ConsoleColor.brightBlack);
  _at(
    console,
    row,
    col + text.length + 2,
    '─' * (width - col - text.length - 8),
    fg: ConsoleColor.brightBlack,
  );
  var cursor = col;
  _at(console, row, cursor, 'SYSTEM:', fg: ConsoleColor.yellow);
  cursor += 8;
  _at(console, row, cursor, ' ONLINE ', fg: ConsoleColor.green);
  cursor += 8;
  _at(console, row, cursor, '| VAULT:', fg: ConsoleColor.yellow);
  cursor += 9;
  _at(console, row, cursor, ' $vault ', fg: ConsoleColor.white);
  cursor += vault.length + 2;
  _at(console, row, cursor, '| HOUSTON-WS-1', fg: ConsoleColor.white);
}

void _frame(
  Console console,
  int row,
  int col,
  int width,
  int height, {
  required bool outer,
}) {
  if (width < 4 || height < 4) return;
  final h = outer ? '─' : '┄';
  final v = outer ? '│' : '┆';
  final tl = outer ? '╭' : '┌';
  final tr = outer ? '╮' : '┐';
  final bl = outer ? '╰' : '└';
  final br = outer ? '╯' : '┘';
  _at(console, row, col, '$tl${h * (width - 2)}$tr', fg: ConsoleColor.cyan);
  for (var i = 1; i < height - 1; i++) {
    _at(console, row + i, col, v, fg: ConsoleColor.cyan);
    _at(console, row + i, col + width - 1, v, fg: ConsoleColor.cyan);
  }
  _at(
    console,
    row + height - 1,
    col,
    '$bl${h * (width - 2)}$br',
    fg: ConsoleColor.cyan,
  );
}

void _panel(Console console, int row, int col, int width, int height) {
  if (width < 4 || height < 4) return;
  _at(
    console,
    row,
    col,
    '┌${'─' * (width - 2)}┐',
    fg: ConsoleColor.cyan,
    maxWidth: width,
  );
  for (var i = 1; i < height - 1; i++) {
    _at(console, row + i, col, '│', fg: ConsoleColor.cyan);
    _at(console, row + i, col + width - 1, '│', fg: ConsoleColor.cyan);
  }
  _at(
    console,
    row + height - 1,
    col,
    '└${'─' * (width - 2)}┘',
    fg: ConsoleColor.cyan,
    maxWidth: width,
  );
  _at(
    console,
    row + 1,
    col + 1,
    ' ' * (width - 2),
    fg: ConsoleColor.brightBlack,
    bg: ConsoleColor.black,
    maxWidth: width - 2,
  );
}

void _writeCenteredLine(
  Console console,
  int row,
  String text, {
  ConsoleColor? fg,
}) {
  final renderText = _singleLine(text);
  final visible = _truncate(renderText, console.windowWidth - 2);
  if (visible.isEmpty) {
    return;
  }
  final col = computeCenteredColumn(
    width: console.windowWidth,
    text: renderText,
  );
  _at(console, row, col, visible, fg: fg, maxWidth: console.windowWidth - col);
}

List<String> buildSplashDeloreanArt() {
  const lines = [
    r"               /\                                             /\               ",
    r"              /  \_________                         _________/  \              ",
    r"             /   /         \                       /         \   \             ",
    r"            /   /           \                     /           \   \            ",
    r"           /___/             \                   /             \___\           ",
    r"               \              \_________________/              /               ",
    r"                \_____   _______________________________  _____/                ",
    r"                      \ [                               ] /                    ",
    r"                  ___  \[     D E L O R E A N           ]/  ___                 ",
    r"                 /   \  |  ===========================  |  /   \                ",
    r"                | [=] | | [■ ■]      | DMC |      [■ ■] | | [=] |                ",
    r"                 \___/  |_______|_______________|_______|  \___/                 ",
    r"                        (O)                           (O)                        ",
    r"                         \=============================/                         ",
  ];
  final artWidth = lines.fold<int>(
    0,
    (maxWidth, line) => line.length > maxWidth ? line.length : maxWidth,
  );
  return lines
      .map((line) => line.padRight(artWidth))
      .toList(growable: false);
}

String _shiftArtLineLeft(String line, [int columns = 1]) {
  if (columns <= 0 || line.isEmpty) {
    return line;
  }
  final leadingSpaces = line.length - line.trimLeft().length;
  if (leadingSpaces == 0) {
    return line;
  }
  final shift = leadingSpaces < columns ? leadingSpaces : columns;
  return line.substring(shift);
}

void _rule(Console console, int row, int width, ConsoleColor color) =>
    _at(console, row, 0, '─' * width, fg: color, maxWidth: width);

void _panelRule(
  Console console,
  int row,
  int col,
  int width,
  ConsoleColor color,
) => _at(console, row, col, '─' * width, fg: color, maxWidth: width);

void _sectionTitleBar(
  Console console,
  int row,
  int col,
  int width,
  String title, {
  String? rightText,
}) {
  _at(console, row, col, ' ' * width, bg: ConsoleColor.yellow, maxWidth: width);
  _at(
    console,
    row,
    col + 2,
    _fit('••• $title •••', (width - 20).clamp(10, width - 4)),
    fg: ConsoleColor.black,
    bg: ConsoleColor.yellow,
    maxWidth: (width - 20).clamp(10, width - 4),
  );
  if (rightText != null) {
    final label = _truncate(rightText, (width ~/ 3).clamp(6, width - 4));
    _at(
      console,
      row,
      col + width - label.length - 2,
      label,
      fg: ConsoleColor.black,
      bg: ConsoleColor.yellow,
      maxWidth: label.length,
    );
  }
}

void _center(
  Console console,
  int row,
  String text,
  ConsoleColor color, {
  int? maxWidth,
}) {
  final width = maxWidth ?? console.windowWidth;
  final visible = _truncate(_singleLine(text), width);
  final col = ((console.windowWidth - visible.length) ~/ 2).clamp(
    0,
    console.windowWidth > 0 ? console.windowWidth - 1 : 0,
  );
  _at(console, row, col, visible, fg: color, maxWidth: width);
}

void _at(
  Console console,
  int row,
  int col,
  String text, {
  ConsoleColor? fg,
  ConsoleColor? bg,
  int? maxWidth,
}) {
  console.cursorPosition = Coordinate(row, col);
  if (bg != null) console.setBackgroundColor(bg);
  if (fg != null) console.setForegroundColor(fg);
  final renderText = _singleLine(text);
  console.write(
    maxWidth == null ? renderText : _truncateAnsi(renderText, maxWidth),
  );
  console.resetColorAttributes();
}

String _fit(String text, int width) =>
    _truncate(_singleLine(text), width).padRight(width);

String _singleLine(String text) =>
    text.replaceAll('\r', '').replaceAll('\n', ' ');

String _truncate(String text, int maxWidth) {
  if (maxWidth <= 0) return '';
  if (text.length <= maxWidth) return text;
  if (maxWidth <= 3) return text.substring(0, maxWidth);
  return '${text.substring(0, maxWidth - 3)}...';
}

String _truncateAnsi(String text, int maxVisibleWidth) {
  if (maxVisibleWidth <= 0) return '';
  final buffer = StringBuffer();
  var visible = 0, index = 0;
  while (index < text.length && visible < maxVisibleWidth) {
    final match = _ansiPattern.matchAsPrefix(text, index);
    if (match != null) {
      buffer.write(match.group(0));
      index = match.end;
      continue;
    }
    buffer.write(text[index]);
    visible++;
    index++;
  }
  buffer.write('\x1B[0m');
  return buffer.toString().padRight(maxVisibleWidth);
}
