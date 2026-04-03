import 'package:dmc/dmc.dart';
import 'package:test/test.dart';

void main() {
  group('DMC UI', () {
    test('starts on the splash screen and navigates splash menu items', () {
      final controller = DmcUiController([
        const DmcUiHistoryEntry(
          snapshotId: 1,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_1.bak',
          timestamp: 100,
          burstId: 10,
        ),
      ]);

      expect(controller.state.view, DmcUiView.splash);
      expect(controller.state.splashSelectedIndex, 0);
      expect(controller.state.selectedMenuItem.label, 'Start dmc Daemon');

      controller.handleInput(DmcUiInput.down);
      expect(controller.state.splashSelectedIndex, 1);
      expect(controller.state.selectedMenuItem.label, 'Status / Active Vaults');
    });

    test('launch menu transitions into the dashboard view', () {
      final controller = DmcUiController([
        const DmcUiHistoryEntry(
          snapshotId: 1,
          filePath: 'alpha.txt',
          snapshotPath: 'alpha_1.bak',
          timestamp: 100,
          burstId: 10,
        ),
      ]);

      controller.handleInput(DmcUiInput.down);
      controller.handleInput(DmcUiInput.down);
      controller.handleInput(DmcUiInput.down);
      final transition = controller.handleInput(DmcUiInput.enter);

      expect(transition.shouldExit, isFalse);
      expect(controller.state.view, DmcUiView.dashboard);
      expect(controller.state.selectedEntry?.filePath, 'alpha.txt');
    });

    test(
      'dashboard still supports selection, restore action, and escape back',
      () {
        final controller = DmcUiController([
          const DmcUiHistoryEntry(
            snapshotId: 1,
            filePath: 'alpha.txt',
            snapshotPath: 'alpha_1.bak',
            timestamp: 100,
            burstId: 10,
          ),
          const DmcUiHistoryEntry(
            snapshotId: 2,
            filePath: 'beta.txt',
            snapshotPath: 'beta_2.bak',
            timestamp: 200,
            burstId: 11,
          ),
        ]);

        controller.handleInput(DmcUiInput.down);
        controller.handleInput(DmcUiInput.down);
        controller.handleInput(DmcUiInput.down);
        controller.handleInput(DmcUiInput.enter);

        controller.handleInput(DmcUiInput.down);
        expect(controller.state.selectedEntry?.filePath, 'beta.txt');

        final restoreTransition = controller.handleInput(DmcUiInput.restore);
        expect(restoreTransition.shouldRestore, isTrue);

        controller.handleInput(DmcUiInput.back);
        expect(controller.state.view, DmcUiView.splash);
      },
    );

    test('dashboard layout stays balanced on wide terminals', () {
      final layout = computeDashboardLayout(width: 140, height: 42);

      expect(layout.leftCol, 1);
      expect(layout.rightCol, layout.leftWidth + 3);
      expect(layout.leftWidth, lessThan(layout.rightWidth));
      expect(layout.panelTop, 5);
      expect(layout.panelHeight, greaterThanOrEqualTo(10));
      expect(layout.statusRow, lessThan(layout.commandRow));
    });

    test(
      'dashboard layout falls back to an even split on narrower terminals',
      () {
        final layout = computeDashboardLayout(width: 90, height: 30);

        expect(layout.leftWidth, closeTo(layout.rightWidth, 1));
        expect(layout.rightCol, layout.leftWidth + 3);
        expect(layout.commandRow, greaterThan(layout.statusRow));
      },
    );

    test('centered column uses visible width and truncation safely', () {
      expect(computeCenteredColumn(width: 80, text: 'DMC'), 38);
      expect(computeCenteredColumn(width: 10, text: '12345678901234567890'), 1);
      expect(computeCenteredColumn(width: 20, text: 'ABC\nDEF'), 6);
      expect(computeCenteredColumn(width: 0, text: 'DMC'), 0);
    });

    test('splash delorean art matches the traced reference lines', () {
      final art = buildSplashDeloreanArt();
      final expected = <String>[
        r"                    â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”",
        r"               â”Œâ”€â”€â”€â”€â”¤â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â”‚â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â–‘â”œâ”€â”€â”€â”€â”",
        r"            â”Œâ”€â”€â”¤â–’â–’â”‚â–‘â–‘â•²         â”‚         â•±â–‘â–‘â”‚â–’â–’â”œâ”€â”€â”",
        r"          â•­â”€â”¤â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚   â”Œâ”€â”€â”€â”€â”€â”´â”€â”€â”€â”€â”€â”   â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”œâ”€â•®",
        r"        â•±  â”‚â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚   â”‚ â”Œâ”€â”€â”€â”€â”€â”€â” â”‚   â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”‚  â•²",
        r"       â”‚   â”‚â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚   â”‚ â”‚      â”‚ â”‚   â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”‚   â”‚",
        r"       â”‚   â”‚â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚   â”‚ â”‚ DMC  â”‚ â”‚   â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”‚   â”‚",
        r"       â”‚   â”‚â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚   â”‚ â””â”€â”€â”€â”€â”€â”€â”˜ â”‚   â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”‚   â”‚",
        r"       â”‚   â”‚â–’â–’â”‚â–’â–’â”‚â–‘â–‘â”‚ â”Œâ”€â”´â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”´â”€â” â”‚â–‘â–‘â”‚â–’â–’â”‚â–’â–’â”‚   â”‚",
        r"       â”‚â–„â–„â–„â””â”€â”€â”´â”€â”€â”´â”€â”€â”´â”€â”¤    â”Œâ”€â”€â”€â”€â”    â”œâ”€â”´â”€â”€â”´â”€â”€â”´â”€â”€â”˜â–„â–„â–„â”‚",
        r"       â”‚â–ˆâ–ˆâ•â•â•â•â•â•â•â•â•â•â•â•â”‚    â”‚ DMCâ”‚    â”‚â•â•â•â•â•â•â•â•â•â•â•â•â–ˆâ–ˆâ”‚",
        r"       â”‚â–„â–„â•â•â•â•â•â•â•â•â•â•â•â•â”‚____â””â”€â”€â”€â”€â”˜____â”‚â•â•â•â•â•â•â•â•â•â•â•â•â–„â–„â”‚",
        r"       â•°â”€â”                                          â”Œâ”€â•¯",
        r"         â•°â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â•²              â•±â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â•¯",
      ];
      for (var i = 0; i < 5; i++) {
        expected[i] = expected[i].substring(1);
      }

      expect(art.map((line) => line.length).toSet(), hasLength(1));
      expect(
        art.map((line) => line.trimRight()).toList(),
        equals([
          r"                    ┌──────────────┬──────────────┐",
          r"               ┌────┤░░░░░░░░░░░░░│░░░░░░░░░░░░░├────┐",
          r"            ┌──┤▒▒│░░╲         │         ╱░░│▒▒├──┐",
          r"          ╭─┤▒▒│▒▒│░░│   ┌─────┴─────┐   │░░│▒▒│▒▒├─╮",
          r"        ╱  │▒▒│▒▒│░░│   │ ┌──────┐ │   │░░│▒▒│▒▒│  ╲",
          r"       │   │▒▒│▒▒│░░│   │ │      │ │   │░░│▒▒│▒▒│   │",
          r"       │   │▒▒│▒▒│░░│   │ │ DMC  │ │   │░░│▒▒│▒▒│   │",
          r"       │   │▒▒│▒▒│░░│   │ └──────┘ │   │░░│▒▒│▒▒│   │",
          r"       │   │▒▒│▒▒│░░│ ┌─┴──────────┴─┐ │░░│▒▒│▒▒│   │",
          r"       │▄▄▄└──┴──┴──┴─┤    ┌────┐    ├─┴──┴──┴──┘▄▄▄│",
          r"       │██════════════│    │ DMC│    │════════════██│",
          r"       │▄▄════════════│____└────┘____│════════════▄▄│",
          r"       ╰─┐                                          ┌─╯",
          r"         ╰─────────────╲              ╱─────────────╯",
        ]),
      );
    });
  });
}
