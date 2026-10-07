import 'dart:collection';

/// Literal matching with Aho–Corasick failure links for larger dictionaries.
/// The caller owns the words and must not mutate them while matching.
final class SubstringMatcher {
  SubstringMatcher(List<String> words)
    : _small = words.length <= 8 ? words : null {
    if (_small != null) return;
    _nodes = [_Node()];
    for (final word in words) {
      var state = 0;
      for (var i = 0; i < word.length; i++) {
        final unit = word.codeUnitAt(i);
        final node = _nodes[state];
        var child = node.next(unit);
        if (child == null) {
          child = _nodes.length;
          _nodes.add(_Node());
          if (node.branches != null) {
            node.branches![unit] = child;
          } else if (node.child == 0) {
            node.unit = unit;
            node.child = child;
          } else {
            node.branches = {node.unit: node.child, unit: child};
          }
        }
        state = child;
      }
      _nodes[state].matches = true;
    }
    final queue = Queue<int>()..add(0);
    void link(int state, int unit, int child) {
      if (state != 0) {
        var fallback = _nodes[state].failure;
        var target = _nodes[fallback].next(unit);
        while (target == null && fallback != 0) {
          fallback = _nodes[fallback].failure;
          target = _nodes[fallback].next(unit);
        }
        final node = _nodes[child];
        node.failure = target ?? 0;
        node.matches = node.matches || _nodes[node.failure].matches;
      }
      queue.add(child);
    }

    while (queue.isNotEmpty) {
      final state = queue.removeFirst();
      final node = _nodes[state];
      final branches = node.branches;
      if (branches != null) {
        for (final edge in branches.entries) {
          link(state, edge.key, edge.value);
        }
      } else if (node.child != 0) {
        link(state, node.unit, node.child);
      }
    }
  }

  final List<String>? _small;
  late final List<_Node> _nodes;

  bool matches(String text) {
    final small = _small;
    if (small != null) {
      for (final word in small) {
        if (text.contains(word)) return true;
      }
      return false;
    }
    if (_nodes[0].matches) return true;
    var state = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      var next = _nodes[state].next(unit);
      while (next == null && state != 0) {
        state = _nodes[state].failure;
        next = _nodes[state].next(unit);
      }
      state = next ?? 0;
      if (_nodes[state].matches) return true;
    }
    return false;
  }
}

/// Most trie nodes have one edge. Allocate a map only at a branch.
final class _Node {
  int unit = -1;
  int child = 0;
  Map<int, int>? branches;
  int failure = 0;
  bool matches = false;

  int? next(int value) {
    final edges = branches;
    return edges == null ? (value == unit ? child : null) : edges[value];
  }
}
