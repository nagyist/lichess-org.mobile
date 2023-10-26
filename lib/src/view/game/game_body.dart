import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chessground/chessground.dart' as cg;

import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/game/game_controller.dart';
import 'package:lichess_mobile/src/model/game/game_status.dart';
import 'package:lichess_mobile/src/model/game/online_game.dart';
import 'package:lichess_mobile/src/model/lobby/lobby_game.dart';
import 'package:lichess_mobile/src/model/lobby/game_seek.dart';
import 'package:lichess_mobile/src/model/settings/board_preferences.dart';
import 'package:lichess_mobile/src/styles/styles.dart';
import 'package:lichess_mobile/src/utils/navigation.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/widgets/adaptive_action_sheet.dart';
import 'package:lichess_mobile/src/widgets/buttons.dart';
import 'package:lichess_mobile/src/widgets/board_table.dart';
import 'package:lichess_mobile/src/widgets/countdown_clock.dart';
import 'package:lichess_mobile/src/widgets/yes_no_dialog.dart';
import 'package:lichess_mobile/src/utils/l10n_context.dart';
import 'package:lichess_mobile/src/utils/chessground_compat.dart';

import 'game_screen_providers.dart';
import 'game_loading_board.dart';
import 'game_player.dart';
import 'status_l10n.dart';

/// Common body for the [LobbyGameScreen] and [StandaloneGameScreen].
///
/// This widget is responsible for displaying the board, the clocks, the players,
/// and the bottom bar.
///
/// The [seek] parameter is only used in the [LobbyGameScreen]. If [seek] is not
/// null, it will display a button to get a new opponent and the game
/// provider will be [lobbyGameProvider].
/// If [seek] is null the game provider will be the [onlineGameProvider]
/// parameterized with the [initialStandAloneId].
class GameBody extends ConsumerWidget {
  /// Constructs a [GameBody].
  ///
  /// You must provide either [seek] or [initialStandAloneId], but not both.
  const GameBody({
    this.seek,
    this.initialStandAloneId,
    required this.id,
    required this.whiteClockKey,
    required this.blackClockKey,
    this.isRematch = false,
  }) : assert(
          (seek != null || initialStandAloneId != null) &&
              !(seek != null && initialStandAloneId != null),
          'Either seek or initialStandAloneId must be provided, but not both.',
        );

  /// The [GameSeek] used to get a new opponent when the game is coming from lobby.
  final GameSeek? seek;

  /// The initial game id when the game was loaded from the [StandAloneGameScreen].
  final GameFullId? initialStandAloneId;

  final GameFullId id;
  final GlobalKey whiteClockKey;
  final GlobalKey blackClockKey;

  /// Whether this game is a rematch.
  ///
  /// Only useful for the loading screen from lobby.
  final bool isRematch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrlProvider = gameControllerProvider(id);

    ref.listen(
      ctrlProvider,
      (prev, state) => _stateListener(
        prev,
        state,
        context: context,
        ref: ref,
      ),
    );

    final shouldShowMaterialDiff = ref.watch(
      boardPreferencesProvider.select(
        (prefs) => prefs.showMaterialDifference,
      ),
    );
    final blindfoldMode = ref.watch(
      boardPreferencesProvider.select(
        (prefs) => prefs.blindfoldMode,
      ),
    );

    final gameStateAsync = ref.watch(ctrlProvider);

    return gameStateAsync.when(
      data: (gameState) {
        final position = gameState.game.positionAt(gameState.stepCursor);
        final sideToMove = position.turn;
        final youAre = gameState.game.youAre ?? Side.white;

        final black = GamePlayer(
          player: gameState.game.black,
          materialDiff: shouldShowMaterialDiff
              ? gameState.game.materialDiffAt(gameState.stepCursor, Side.black)
              : null,
          timeToMove: sideToMove == Side.black ? gameState.timeToMove : null,
          shouldLinkToUserProfile: youAre != Side.black,
          mePlaying: youAre == Side.black,
          zenMode: gameState.isZenModeEnabled,
          confirmMoveCallbacks:
              youAre == Side.black && gameState.moveToConfirm != null
                  ? (
                      confirm: () {
                        ref.read(ctrlProvider.notifier).confirmMove();
                      },
                      cancel: () {
                        ref.read(ctrlProvider.notifier).cancelMove();
                      },
                    )
                  : null,
          clock: gameState.game.clock != null
              ? CountdownClock(
                  key: blackClockKey,
                  duration: gameState.game.clock!.black,
                  active: gameState.activeClockSide == Side.black,
                  emergencyThreshold: youAre == Side.black
                      ? gameState.game.clock?.emergency
                      : null,
                  onFlag: youAre == Side.black
                      ? () => ref.read(ctrlProvider.notifier).onFlag()
                      : null,
                )
              : null,
        );
        final white = GamePlayer(
          player: gameState.game.white,
          materialDiff: shouldShowMaterialDiff
              ? gameState.game.materialDiffAt(gameState.stepCursor, Side.white)
              : null,
          timeToMove: sideToMove == Side.white ? gameState.timeToMove : null,
          shouldLinkToUserProfile: youAre != Side.white,
          mePlaying: youAre == Side.white,
          zenMode: gameState.isZenModeEnabled,
          confirmMoveCallbacks:
              youAre == Side.white && gameState.moveToConfirm != null
                  ? (
                      confirm: () {
                        ref.read(ctrlProvider.notifier).confirmMove();
                      },
                      cancel: () {
                        ref.read(ctrlProvider.notifier).cancelMove();
                      },
                    )
                  : null,
          clock: gameState.game.clock != null
              ? CountdownClock(
                  key: whiteClockKey,
                  duration: gameState.game.clock!.white,
                  active: gameState.activeClockSide == Side.white,
                  emergencyThreshold: youAre == Side.white
                      ? gameState.game.clock?.emergency
                      : null,
                  onFlag: youAre == Side.white
                      ? () => ref.read(ctrlProvider.notifier).onFlag()
                      : null,
                )
              : null,
        );

        final topPlayer = youAre == Side.white ? black : white;
        final bottomPlayer = youAre == Side.white ? white : black;
        final isBoardTurned = ref.watch(isBoardTurnedProvider);

        final content = Column(
          children: [
            Expanded(
              child: SafeArea(
                bottom: false,
                child: BoardTable(
                  boardSettingsOverrides: BoardSettingsOverrides(
                    autoQueenPromotion: gameState.canAutoQueen,
                    autoQueenPromotionOnPremove:
                        gameState.canAutoQueenOnPremove,
                    blindfoldMode: blindfoldMode,
                  ),
                  onMove: (move, {isDrop, isPremove}) {
                    ref.read(ctrlProvider.notifier).onUserMove(
                          Move.fromUci(move.uci)!,
                          isPremove: isPremove,
                          isDrop: isDrop,
                        );
                  },
                  onPremove: gameState.canPremove
                      ? (move) {
                          ref.read(ctrlProvider.notifier).setPremove(move);
                        }
                      : null,
                  boardData: cg.BoardData(
                    interactableSide:
                        gameState.game.playable && !gameState.isReplaying
                            ? youAre == Side.white
                                ? cg.InteractableSide.white
                                : cg.InteractableSide.black
                            : cg.InteractableSide.none,
                    orientation: isBoardTurned ? youAre.opposite.cg : youAre.cg,
                    fen: position.fen,
                    lastMove: gameState.game.moveAt(gameState.stepCursor)?.cg,
                    isCheck: position.isCheck,
                    sideToMove: sideToMove.cg,
                    validMoves: algebraicLegalMoves(position),
                    premove: gameState.premove,
                  ),
                  topTable: topPlayer,
                  bottomTable: gameState.canShowClaimWinCountdown &&
                          gameState.opponentLeftCountdown != null
                      ? _ClaimWinCountdown(
                          duration: gameState.opponentLeftCountdown!,
                        )
                      : bottomPlayer,
                  moves: gameState.game.steps
                      .skip(1)
                      .map((e) => e.sanMove!.san)
                      .toList(growable: false),
                  currentMoveIndex: gameState.stepCursor,
                  onSelectMove: (moveIndex) {
                    ref.read(ctrlProvider.notifier).cursorAt(moveIndex);
                  },
                ),
              ),
            ),
            _GameBottomBar(
              seek: seek,
              id: id,
              gameState: gameState,
            ),
          ],
        );

        return WillPopScope(
          onWillPop: gameState.game.playable ? () async => false : null,
          child: content,
        );
      },
      loading: () => WillPopScope(
        onWillPop: () async => false,
        child: seek != null
            ? LobbyGameLoadingBoard(seek!, isRematch: isRematch)
            : const StandaloneGameLoadingBoard(),
      ),
      error: (e, s) {
        debugPrint(
          'SEVERE: [GameBody] could not load game data; $e\n$s',
        );
        return const WillPopScope(
          onWillPop: null,
          child: LoadGameError(),
        );
      },
    );
  }

  void _stateListener(
    AsyncValue<GameState>? prev,
    AsyncValue<GameState> state, {
    required BuildContext context,
    required WidgetRef ref,
  }) {
    if (prev?.hasValue == true && state.hasValue) {
      // If the game is no longer playable, show the game end dialog.
      if (prev!.requireValue.game.playable == true &&
          state.requireValue.game.playable == false) {
        Timer(const Duration(milliseconds: 500), () {
          if (context.mounted) {
            showAdaptiveDialog<void>(
              context: context,
              builder: (context) => _GameEndDialog(id: id, seek: seek),
              barrierDismissible: true,
            );
          }
        });
      }

      // Opponent is gone long enough to show the claim win dialog.
      if (!prev.requireValue.game.canClaimWin &&
          state.requireValue.game.canClaimWin) {
        if (context.mounted) {
          showAdaptiveDialog<void>(
            context: context,
            builder: (context) => _ClaimWinDialog(id: id),
            barrierDismissible: true,
          );
        }
      }

      if (state.requireValue.redirectGameId != null) {
        // Be sure to pop any dialogs that might be on top of the game screen.
        Navigator.of(context).popUntil((route) => route is! RawDialogRoute);
        if (seek != null) {
          ref
              .read(lobbyGameProvider(seek!).notifier)
              .rematch(state.requireValue.redirectGameId!);
        } else if (initialStandAloneId != null) {
          ref
              .read(onlineGameProvider(initialStandAloneId!).notifier)
              .rematch(state.requireValue.redirectGameId!);
        }
      }
    }
  }
}

class _GameBottomBar extends ConsumerWidget {
  const _GameBottomBar({
    this.seek,
    required this.id,
    required this.gameState,
  });

  final GameSeek? seek;
  final GameFullId id;
  final GameState gameState;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: Styles.horizontalBodyPadding,
      color: defaultTargetPlatform == TargetPlatform.iOS
          ? CupertinoTheme.of(context).barBackgroundColor
          : Theme.of(context).bottomAppBarTheme.color,
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            BottomBarButton(
              label: context.l10n.menu,
              shortLabel: context.l10n.menu,
              onTap: () {
                _showGameMenu(context, ref);
              },
              icon: Icons.menu,
            ),
            if (gameState.game.playable &&
                gameState.game.opponent?.offeringDraw == true)
              BottomBarButton(
                label: context.l10n.yourOpponentOffersADraw,
                highlighted: true,
                shortLabel: context.l10n.draw,
                onTap: () {
                  showAdaptiveDialog<void>(
                    context: context,
                    builder: (context) => _GameNegotiationDialog(
                      title: Text(context.l10n.yourOpponentOffersADraw),
                      onAccept: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .offerOrAcceptDraw();
                      },
                      onDecline: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .cancelOrDeclineDraw();
                      },
                    ),
                    barrierDismissible: true,
                  );
                },
                icon: Icons.handshake_outlined,
              )
            else if (gameState.game.playable &&
                gameState.game.isThreefoldRepetition == true)
              BottomBarButton(
                label: context.l10n.threefoldRepetition,
                highlighted: true,
                shortLabel: context.l10n.draw,
                onTap: () {
                  showAdaptiveDialog<void>(
                    context: context,
                    builder: (context) => _ThreefoldDialog(id: id),
                    barrierDismissible: true,
                  );
                },
                icon: Icons.handshake_outlined,
              )
            else if (gameState.game.playable &&
                gameState.game.opponent?.proposingTakeback == true)
              BottomBarButton(
                label: context.l10n.yourOpponentProposesATakeback,
                highlighted: true,
                shortLabel: context.l10n.takeback,
                onTap: () {
                  showAdaptiveDialog<void>(
                    context: context,
                    builder: (context) => _GameNegotiationDialog(
                      title: Text(context.l10n.yourOpponentProposesATakeback),
                      onAccept: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .acceptTakeback();
                      },
                      onDecline: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .cancelOrDeclineTakeback();
                      },
                    ),
                    barrierDismissible: true,
                  );
                },
                icon: CupertinoIcons.arrowshape_turn_up_left,
              )
            else if (gameState.game.finished)
              BottomBarButton(
                label: context.l10n.gameAnalysis,
                shortLabel: 'Analysis',
                icon: Icons.biotech,
                onTap: () => pushPlatformRoute(
                  context,
                  builder: (_) => AnalysisScreen(
                    options: gameState.analysisOptions,
                    title: context.l10n.gameAnalysis,
                  ),
                ),
              )
            else
              const SizedBox(
                width: 44.0,
              ),
            // TODO replace this space with chat button
            const SizedBox(
              width: 44.0,
            ),
            RepeatButton(
              onLongPress:
                  gameState.canGoBackward ? () => _moveBackward(ref) : null,
              child: BottomBarButton(
                onTap:
                    gameState.canGoBackward ? () => _moveBackward(ref) : null,
                label: 'Previous',
                shortLabel: 'Previous',
                icon: CupertinoIcons.chevron_back,
                showAndroidTooltip: false,
              ),
            ),
            RepeatButton(
              onLongPress:
                  gameState.canGoForward ? () => _moveForward(ref) : null,
              child: BottomBarButton(
                onTap: gameState.canGoForward ? () => _moveForward(ref) : null,
                label: context.l10n.next,
                shortLabel: context.l10n.next,
                icon: CupertinoIcons.chevron_forward,
                showAndroidTooltip: false,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _moveForward(WidgetRef ref) {
    ref.read(gameControllerProvider(id).notifier).cursorForward();
  }

  void _moveBackward(WidgetRef ref) {
    ref.read(gameControllerProvider(id).notifier).cursorBackward();
  }

  Future<void> _showGameMenu(BuildContext context, WidgetRef ref) {
    return showAdaptiveActionSheet(
      context: context,
      actions: [
        BottomSheetAction(
          label: Text(context.l10n.flipBoard),
          onPressed: (context) {
            ref.read(isBoardTurnedProvider.notifier).toggle();
          },
        ),
        if (gameState.game.abortable)
          BottomSheetAction(
            label: Text(context.l10n.abortGame),
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).abortGame();
            },
          ),
        if (gameState.game.clock != null && gameState.game.canGiveTime)
          BottomSheetAction(
            label: Text(
              context.l10n.giveNbSeconds(
                gameState.game.clock!.moreTime?.inSeconds ?? 15,
              ),
            ),
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).moreTime();
            },
          ),
        if (gameState.game.canTakeback)
          BottomSheetAction(
            label: Text(context.l10n.takeback),
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).offerTakeback();
            },
          ),
        if (gameState.game.player?.proposingTakeback == true)
          BottomSheetAction(
            label: const Text('Cancel takeback offer'),
            isDestructiveAction: true,
            onPressed: (context) {
              ref
                  .read(gameControllerProvider(id).notifier)
                  .cancelOrDeclineTakeback();
            },
          ),
        if (gameState.game.player?.offeringDraw == true)
          BottomSheetAction(
            label: const Text('Cancel draw offer'),
            isDestructiveAction: true,
            onPressed: (context) {
              ref
                  .read(gameControllerProvider(id).notifier)
                  .cancelOrDeclineDraw();
            },
          )
        else if (gameState.canOfferDraw)
          BottomSheetAction(
            label: Text(context.l10n.offerDraw),
            onPressed: gameState.shouldConfirmResignAndDrawOffer
                ? (context) => _showConfirmDialog(
                      context,
                      description: Text(context.l10n.offerDraw),
                      onConfirm: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .offerOrAcceptDraw();
                      },
                    )
                : (context) {
                    ref
                        .read(gameControllerProvider(id).notifier)
                        .offerOrAcceptDraw();
                  },
          ),
        if (gameState.game.resignable)
          BottomSheetAction(
            label: Text(context.l10n.resign),
            dismissOnPress: false,
            onPressed: gameState.shouldConfirmResignAndDrawOffer
                ? (context) => _showConfirmDialog(
                      context,
                      description: Text(context.l10n.resignTheGame),
                      onConfirm: () {
                        ref
                            .read(gameControllerProvider(id).notifier)
                            .resignGame();
                      },
                    )
                : (context) {
                    ref.read(gameControllerProvider(id).notifier).resignGame();
                  },
          ),
        if (gameState.game.canClaimWin) ...[
          BottomSheetAction(
            label: Text(context.l10n.forceDraw),
            dismissOnPress: true,
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).forceDraw();
            },
          ),
          BottomSheetAction(
            label: Text(context.l10n.forceResignation),
            dismissOnPress: true,
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).forceResign();
            },
          ),
        ],
        if (gameState.game.player?.offeringRematch == true)
          BottomSheetAction(
            label: Text(context.l10n.cancelRematchOffer),
            dismissOnPress: true,
            isDestructiveAction: true,
            onPressed: (context) {
              ref.read(gameControllerProvider(id).notifier).declineRematch();
            },
          )
        else if (gameState.canOfferRematch &&
            gameState.game.opponent?.onGame == true)
          BottomSheetAction(
            label: Text(context.l10n.rematch),
            dismissOnPress: true,
            onPressed: (context) {
              ref
                  .read(gameControllerProvider(id).notifier)
                  .proposeOrAcceptRematch();
            },
          ),
        if (gameState.canGetNewOpponent && seek != null)
          BottomSheetAction(
            label: Text(context.l10n.newOpponent),
            onPressed: (_) {
              ref.read(lobbyGameProvider(seek!).notifier).newOpponent();
            },
          ),
        if (gameState.game.finished)
          BottomSheetAction(
            label: const Text('Show result'),
            onPressed: (_) {
              showAdaptiveDialog<void>(
                context: context,
                builder: (context) => _GameEndDialog(id: id, seek: seek),
                barrierDismissible: true,
              );
            },
          ),
      ],
    );
  }

  Future<void> _showConfirmDialog(
    BuildContext context, {
    required Widget description,
    required VoidCallback onConfirm,
  }) async {
    await Navigator.of(context).maybePop();
    if (context.mounted) {
      final result = await showAdaptiveDialog<bool>(
        context: context,
        builder: (context) => YesNoDialog(
          title: const Text('Are you sure?'),
          content: description,
          onYes: () {
            return Navigator.of(context).pop(true);
          },
          onNo: () => Navigator.of(context).pop(false),
        ),
      );
      if (result == true) {
        onConfirm();
      }
    }
  }
}

class _GameEndDialog extends ConsumerStatefulWidget {
  const _GameEndDialog({required this.id, this.seek});

  final GameFullId id;
  final GameSeek? seek;

  @override
  ConsumerState<_GameEndDialog> createState() => _GameEndDialogState();
}

class _GameEndDialogState extends ConsumerState<_GameEndDialog> {
  late Timer _buttonActivationTimer;
  bool _activateButtons = false;

  @override
  void initState() {
    _buttonActivationTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          _activateButtons = true;
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _buttonActivationTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrlProvider = gameControllerProvider(widget.id);
    final gameState = ref.watch(ctrlProvider).requireValue;

    final showWinner = gameState.game.winner != null
        ? ' • ${gameState.game.winner == Side.white ? context.l10n.whiteIsVictorious : context.l10n.blackIsVictorious}'
        : '';

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (gameState.game.status.value >= GameStatus.mate.value)
          Text(
            gameState.game.winner == null
                ? '½-½'
                : gameState.game.winner == Side.white
                    ? '1-0'
                    : '0-1',
            style: const TextStyle(
              fontSize: 18.0,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 6.0),
        Text(
          '${gameStatusL10n(context, gameState)}$showWinner',
          style: const TextStyle(
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16.0),
        if (gameState.game.player?.offeringRematch == true)
          SecondaryButton(
            semanticsLabel: context.l10n.cancelRematchOffer,
            onPressed: () {
              ref.read(ctrlProvider.notifier).declineRematch();
            },
            child: Text(context.l10n.cancelRematchOffer),
          )
        else if (gameState.canOfferRematch)
          SecondaryButton(
            semanticsLabel: context.l10n.rematch,
            onPressed: _activateButtons &&
                    gameState.game.opponent?.onGame == true
                ? () {
                    ref.read(ctrlProvider.notifier).proposeOrAcceptRematch();
                  }
                : null,
            glowing: gameState.game.opponent?.offeringRematch == true,
            child: Text(context.l10n.rematch),
          ),
        if (gameState.canGetNewOpponent && widget.seek != null)
          SecondaryButton(
            semanticsLabel: context.l10n.newOpponent,
            onPressed: _activateButtons
                ? () {
                    ref
                        .read(lobbyGameProvider(widget.seek!).notifier)
                        .newOpponent();
                    // Other alert dialogs may be shown before this one, so be sure to pop them all
                    Navigator.of(context)
                        .popUntil((route) => route is! RawDialogRoute);
                  }
                : null,
            child: Text(context.l10n.newOpponent),
          ),
        SecondaryButton(
          semanticsLabel: context.l10n.analysis,
          onPressed: () => pushPlatformRoute(
            context,
            builder: (_) => AnalysisScreen(
              options: gameState.analysisOptions,
              title: context.l10n.gameAnalysis,
            ),
          ),
          child: Text(context.l10n.analysis),
        ),
      ],
    );

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoAlertDialog(
        content: content,
      );
    } else {
      return Dialog(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: content,
        ),
      );
    }
  }
}

class _GameNegotiationDialog extends StatelessWidget {
  const _GameNegotiationDialog({
    required this.title,
    required this.onAccept,
    required this.onDecline,
  });

  final Widget title;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    void decline() {
      Navigator.of(context).pop();
      onDecline();
    }

    void accept() {
      Navigator.of(context).pop();
      onAccept();
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoAlertDialog(
        content: title,
        actions: [
          CupertinoDialogAction(
            onPressed: accept,
            child: Text(context.l10n.accept),
          ),
          CupertinoDialogAction(
            onPressed: decline,
            child: Text(context.l10n.decline),
          ),
        ],
      );
    } else {
      return AlertDialog(
        content: title,
        actions: [
          TextButton(
            onPressed: accept,
            child: Text(context.l10n.accept),
          ),
          TextButton(
            onPressed: decline,
            child: Text(context.l10n.decline),
          ),
        ],
      );
    }
  }
}

class _ThreefoldDialog extends ConsumerWidget {
  const _ThreefoldDialog({
    required this.id,
  });

  final GameFullId id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = Text(context.l10n.threefoldRepetition);

    void decline() {
      Navigator.of(context).pop();
    }

    void accept() {
      Navigator.of(context).pop();
      ref.read(gameControllerProvider(id).notifier).claimDraw();
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoAlertDialog(
        content: content,
        actions: [
          CupertinoDialogAction(
            onPressed: accept,
            child: Text(context.l10n.claimADraw),
          ),
          CupertinoDialogAction(
            onPressed: decline,
            child: Text(context.l10n.cancel),
          ),
        ],
      );
    } else {
      return AlertDialog(
        content: content,
        actions: [
          TextButton(
            onPressed: accept,
            child: Text(context.l10n.claimADraw),
          ),
          TextButton(
            onPressed: decline,
            child: Text(context.l10n.cancel),
          ),
        ],
      );
    }
  }
}

class _ClaimWinDialog extends ConsumerWidget {
  const _ClaimWinDialog({
    required this.id,
  });

  final GameFullId id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrlProvider = gameControllerProvider(id);
    final gameState = ref.watch(ctrlProvider).requireValue;

    final content = Text(context.l10n.opponentLeftChoices);

    void onClaimWin() {
      Navigator.of(context).pop();
      ref.read(ctrlProvider.notifier).forceResign();
    }

    void onClaimDraw() {
      Navigator.of(context).pop();
      ref.read(ctrlProvider.notifier).forceDraw();
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoAlertDialog(
        content: content,
        actions: [
          CupertinoDialogAction(
            onPressed: gameState.game.canClaimWin ? onClaimWin : null,
            isDefaultAction: true,
            child: Text(context.l10n.forceResignation),
          ),
          CupertinoDialogAction(
            onPressed: gameState.game.canClaimWin ? onClaimDraw : null,
            child: Text(context.l10n.forceDraw),
          ),
        ],
      );
    } else {
      return AlertDialog(
        content: content,
        actions: [
          TextButton(
            onPressed: gameState.game.canClaimWin ? onClaimWin : null,
            child: Text(context.l10n.forceResignation),
          ),
          TextButton(
            onPressed: gameState.game.canClaimWin ? onClaimDraw : null,
            child: Text(context.l10n.forceDraw),
          ),
        ],
      );
    }
  }
}

class _ClaimWinCountdown extends StatelessWidget {
  const _ClaimWinCountdown({
    required this.duration,
  });

  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final secs = duration.inSeconds.remainder(60);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(10.0),
        child: Text(context.l10n.opponentLeftCounter(secs)),
      ),
    );
  }
}