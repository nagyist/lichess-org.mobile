import 'dart:async';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/service/move_feedback.dart';
import 'package:lichess_mobile/src/model/common/service/sound_service.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/node.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/engine/engine_evaluation.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/model/settings/analysis_preferences.dart';
import 'package:lichess_mobile/src/utils/rate_limit.dart';
import 'package:lichess_mobile/src/model/analysis/opening_service.dart';

part 'analysis_controller.g.dart';
part 'analysis_controller.freezed.dart';

@freezed
class AnalysisOptions with _$AnalysisOptions {
  const factory AnalysisOptions({
    required ID id,
    required bool isLocalEvaluationAllowed,
    required Side orientation,
    required Variant variant,

    /// The PGN of the game to analyze.
    /// The move list can be empty.
    /// It can contain a FEN header for initial position.
    /// If it contains a Variant header, it will be ignored.
    required String pgn,
    int? initialMoveCursor,
    LightOpening? opening,
  }) = _AnalysisOptions;
}

@riverpod
class AnalysisController extends _$AnalysisController {
  late final Root _root;

  final _engineEvalDebounce = Debouncer(const Duration(milliseconds: 500));

  Timer? _startEngineEvalTimer;

  @override
  AnalysisState build(AnalysisOptions options) {
    ref.onDispose(() {
      _startEngineEvalTimer?.cancel();
      _engineEvalDebounce.dispose();
    });

    UciPath path = UciPath.empty;
    Move? lastMove;
    IMap<String, String>? pgnHeaders =
        options.id is GameId ? null : _defaultPgnHeaders;
    IList<String>? rootComments;

    final game = PgnGame.parsePgn(options.pgn);
    // only include headers if the game is not an online lichess game
    if (options.id is! GameId) {
      pgnHeaders = pgnHeaders?.addMap(game.headers) ?? IMap(game.headers);
      rootComments = IList(game.comments);
    }

    _root = Root.fromPgnGame(game, (root, branch, isMainline) {
      if (isMainline &&
          options.initialMoveCursor != null &&
          branch.position.ply <= options.initialMoveCursor!) {
        path = path + branch.id;
        lastMove = branch.sanMove.move;
      }
      if (isMainline && options.opening == null && branch.position.ply <= 2) {
        _fetchOpening(root, path);
      }
    });

    final currentPath =
        options.initialMoveCursor == null ? _root.mainlinePath : path;
    final currentNode = _root.nodeAt(currentPath);

    // don't use ref.watch here: we don't want to invalidate state when the
    // analysis preferences change
    final prefs = ref.read(analysisPreferencesProvider);

    final evalContext = EvaluationContext(
      variant: options.variant,
      initialPosition: _root.position,
      contextId: options.id,
      multiPv: prefs.numEvalLines,
      cores: prefs.numEngineCores,
    );

    _startEngineEvalTimer = Timer(const Duration(milliseconds: 300), () {
      _startEngineEval();
    });

    return AnalysisState(
      id: options.id,
      currentPath: currentPath,
      root: _root.view,
      currentNode: AnalysisCurrentNode.fromNode(currentNode),
      pgnHeaders: pgnHeaders,
      pgnRootComments: rootComments,
      lastMove: lastMove,
      pov: options.orientation,
      evaluationContext: evalContext,
      contextOpening: options.opening,
      isLocalEvaluationAllowed: options.isLocalEvaluationAllowed,
      isLocalEvaluationEnabled: prefs.enableLocalEvaluation,
      shouldShowComments: true,
    );
  }

  void onUserMove(Move move) {
    if (!state.position.isLegal(move)) return;
    final (newPath, isNewNode) = _root.addMoveAt(state.currentPath, move);
    if (newPath != null) {
      _setPath(newPath, isNewNode: isNewNode);
    }
  }

  void userNext() {
    if (!state.currentNode.hasChild) return;
    _setPath(
      state.currentPath + _root.nodeAt(state.currentPath).children.first.id,
      replaying: true,
    );
  }

  void toggleComments() {
    state = state.copyWith(shouldShowComments: !state.shouldShowComments);
  }

  void toggleBoard() {
    state = state.copyWith(pov: state.pov.opposite);
  }

  void userPrevious() {
    _setPath(state.currentPath.penultimate, replaying: true);
  }

  void userJump(UciPath path) {
    _setPath(path);
  }

  void toggleLocalEvaluation() {
    ref
        .read(analysisPreferencesProvider.notifier)
        .toggleEnableLocalEvaluation();

    state = state.copyWith(
      isLocalEvaluationEnabled: !state.isLocalEvaluationEnabled,
    );

    if (state.isEngineAvailable) {
      _startEngineEval();
    } else {
      _stopEngineEval();
    }
  }

  void setNumEvalLines(int numEvalLines) {
    ref
        .read(analysisPreferencesProvider.notifier)
        .setNumEvalLines(numEvalLines);

    _stopEngineEval();

    _root.updateAll((node) => node.eval = null);

    state = state.copyWith(
      evaluationContext: state.evaluationContext.copyWith(
        multiPv: numEvalLines,
      ),
      currentNode:
          AnalysisCurrentNode.fromNode(_root.nodeAt(state.currentPath)),
    );

    _startEngineEval();
  }

  void setEngineCores(int numEngineCores) {
    ref
        .read(analysisPreferencesProvider.notifier)
        .setEngineCores(numEngineCores);

    _stopEngineEval();

    state = state.copyWith(
      evaluationContext: state.evaluationContext.copyWith(
        cores: numEngineCores,
      ),
    );

    _startEngineEval();
  }

  void updatePgnHeader(String key, String value) {
    final headers = state.pgnHeaders?.add(key, value) ?? IMap({key: value});
    state = state.copyWith(pgnHeaders: headers);
  }

  /// Gets the node and maybe the associated branch opening at the given path.
  (Node, Opening?) _nodeOpeningAt(Node node, UciPath path, [Opening? opening]) {
    if (path.isEmpty) return (node, opening);
    final child = node.childById(path.head!);
    if (child != null) {
      return _nodeOpeningAt(child, path.tail, child.opening ?? opening);
    } else {
      return (node, opening);
    }
  }

  String makeGamePgn() {
    return _root.makePgn(state.pgnHeaders, state.pgnRootComments);
  }

  void _setPath(
    UciPath path, {
    bool isNewNode = false,
    bool replaying = false,
  }) {
    final pathChange = state.currentPath != path;
    final (currentNode, opening) = _nodeOpeningAt(_root, path);

    if (currentNode is Branch) {
      if (!replaying) {
        final isForward = path.size > state.currentPath.size;
        if (isForward) {
          final isCheck = currentNode.sanMove.isCheck;
          if (currentNode.sanMove.isCapture) {
            ref
                .read(moveFeedbackServiceProvider)
                .captureFeedback(check: isCheck);
          } else {
            ref.read(moveFeedbackServiceProvider).moveFeedback(check: isCheck);
          }
        }
      } else {
        final soundService = ref.read(soundServiceProvider);
        if (currentNode.sanMove.isCapture) {
          soundService.play(Sound.capture);
        } else {
          soundService.play(Sound.move);
        }
      }

      if (currentNode.opening == null && currentNode.position.ply <= 30) {
        _fetchOpening(_root, path);
      }

      state = state.copyWith(
        currentPath: path,
        currentNode: AnalysisCurrentNode.fromNode(currentNode),
        lastMove: currentNode.sanMove.move,
        currentBranchOpening: opening,
        // root view is only used to display move list, so we need to
        // recompute the root view only when a new node is added
        root: isNewNode ? _root.view : state.root,
      );
    } else {
      state = state.copyWith(
        currentPath: path,
        currentNode: AnalysisCurrentNode.fromNode(currentNode),
        currentBranchOpening: opening,
        lastMove: null,
      );
    }

    if (pathChange) {
      _debouncedStartEngineEval();
    }
  }

  Future<void> _fetchOpening(Node fromNode, UciPath path) async {
    if (!kOpeningAllowedVariants.contains(options.variant)) return;

    final moves = fromNode.nodesOn(path).map((node) => node.sanMove.move);
    if (moves.isEmpty) return;
    if (moves.length > 40) return;

    final opening =
        await ref.read(openingServiceProvider).fetchFromMoves(moves);

    if (opening != null) {
      fromNode.updateAt(path, (node) => node.opening = opening);

      if (state.currentPath == path) {
        state = state.copyWith(
          currentNode: AnalysisCurrentNode.fromNode(fromNode.nodeAt(path)),
        );
      }
    }
  }

  void _startEngineEval() {
    if (!state.isEngineAvailable) return;
    ref
        .read(
          engineEvaluationProvider(state.evaluationContext).notifier,
        )
        .start(
          state.currentPath,
          _root.nodesOn(state.currentPath).map(Step.fromNode),
          state.currentNode.position,
          shouldEmit: (work) => work.path == state.currentPath,
        )
        ?.forEach(
          (t) => _root.updateAt(t.$1.path, (node) => node.eval = t.$2),
        );
  }

  void _debouncedStartEngineEval() {
    _engineEvalDebounce(() {
      _startEngineEval();
    });
  }

  void _stopEngineEval() {
    ref.read(engineEvaluationProvider(state.evaluationContext).notifier).stop();
  }
}

@freezed
class AnalysisState with _$AnalysisState {
  const AnalysisState._();

  const factory AnalysisState({
    /// Immutable view of the whole tree
    required ViewRoot root,

    /// The current node in the analysis view.
    ///
    /// This is an immutable copy of the actual [Node] at the `currentPath`.
    /// We don't want to use [Node.view] here because it'd copy the whole tree
    /// under the current node and it's expensive.
    required AnalysisCurrentNode currentNode,

    /// The path to the current node in the analysis view.
    required UciPath currentPath,

    /// Analysis ID, useful for the evaluation context.
    required ID id,

    /// The side to display the board from.
    required Side pov,

    /// Context for engine evaluation.
    required EvaluationContext evaluationContext,

    /// Whether local evaluation is allowed for this analysis.
    required bool isLocalEvaluationAllowed,

    /// Whether the user has enabled local evaluation.
    required bool isLocalEvaluationEnabled,

    /// Whether to show PGN comments in the tree view.
    required bool shouldShowComments,

    /// The last move played.
    Move? lastMove,

    /// Opening of the analysis context (from lichess archived games).
    Opening? contextOpening,

    /// The opening of the current branch.
    Opening? currentBranchOpening,

    /// The PGN headers of the game.
    ///
    /// This field is only used with user submitted PGNS.
    IMap<String, String>? pgnHeaders,

    /// The PGN comments of the game.
    ///
    /// This field is only used with user submitted PGNS.
    IList<String>? pgnRootComments,
  }) = _AnalysisState;

  IMap<String, ISet<String>> get validMoves =>
      algebraicLegalMoves(currentNode.position);

  bool get isEngineAvailable =>
      isLocalEvaluationAllowed &&
      engineSupportedVariants.contains(
        evaluationContext.variant,
      ) &&
      isLocalEvaluationEnabled;

  Position get position => currentNode.position;
  bool get canGoNext => currentNode.hasChild;
  bool get canGoBack => currentPath.size > UciPath.empty.size;
}

@freezed
class AnalysisCurrentNode with _$AnalysisCurrentNode {
  const factory AnalysisCurrentNode({
    required Position position,
    required bool hasChild,
    required bool isRoot,
    SanMove? sanMove,
    Opening? opening,
    ClientEval? eval,
    IList<String>? startingComments,
    IList<String>? comments,
    IList<int>? nags,
  }) = _AnalysisCurrentNode;

  factory AnalysisCurrentNode.fromNode(Node node) {
    if (node is Branch) {
      return AnalysisCurrentNode(
        sanMove: node.sanMove,
        position: node.position,
        isRoot: node is Root,
        hasChild: node.children.isNotEmpty,
        opening: node.opening,
        eval: node.eval,
        startingComments: IList(node.startingComments),
        comments: IList(node.comments),
        nags: IList(node.nags),
      );
    } else {
      return AnalysisCurrentNode(
        position: node.position,
        hasChild: node.children.isNotEmpty,
        isRoot: node is Root,
        opening: node.opening,
        eval: node.eval,
      );
    }
  }
}

const IMap<String, String> _defaultPgnHeaders = IMapConst({
  'Event': '?',
  'Site': '?',
  'Date': '????.??.??',
  'Round': '?',
  'White': '?',
  'Black': '?',
  'Result': '*',
  'WhiteElo': '?',
  'BlackElo': '?',
});
